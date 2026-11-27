// The app's side of CmuxMobileSystemUI.framework: it loads the framework on
// first use and offers the call sites SwiftUI and UIKit helpers over it. Not
// compiled into the framework (only SystemUIContract.swift is).
#if os(iOS)
public import Foundation
public import SwiftUI
public import UIKit
public import UniformTypeIdentifiers
import os

/// AuthenticationServices, SafariServices, StoreKit, PhotosUI and QuickLook,
/// loaded on first use. The app links none of them: each adds about 1.55 s
/// before `main` on a cold launch (2.1 s together), so they live in
/// `Frameworks/CmuxMobileSystemUI.framework`, embedded but not linked.
public enum SystemUI {
    /// The framework's provider, loaded on the first call from any thread and
    /// kept. Nil when the framework is missing or would not load (logged once);
    /// callers then degrade (no picker, Safari opens the link, no purchase).
    public static var provider: (any SystemUIProvider)? { SystemUILoader.provider }

    static let log = Logger(subsystem: "dev.cmux.mobile", category: "SystemUI")
}

/// Loads the framework once. A lock, not an actor: the store reaches the
/// provider off the main actor, and the views reach it synchronously on it.
private enum SystemUILoader {
    /// The framework's principal class (its Info.plist's `NSPrincipalClass`).
    static let principalClassName = "CMXSystemUIProviderImplementation"
    static let frameworkName = "CmuxMobileSystemUI.framework"

    private enum State {
        case unloaded
        case loaded(any SystemUIProvider)
        case failed
    }

    /// The provider is an Objective-C object the framework hands out once and
    /// never mutates; the lock guards which state the loader is in.
    private static let state = OSAllocatedUnfairLock<State>(uncheckedState: .unloaded)

    static var provider: (any SystemUIProvider)? {
        state.withLockUnchecked { state in
            switch state {
            case .loaded(let provider):
                return provider
            case .failed:
                return nil
            case .unloaded:
                let provider = load()
                state = provider.map(State.loaded) ?? .failed
                return provider
            }
        }
    }

    private static func load() -> (any SystemUIProvider)? {
        let started = ContinuousClock.now
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent(frameworkName, isDirectory: true),
              let bundle = Bundle(url: url) else {
            SystemUI.log.error("load failed: no \(frameworkName, privacy: .public) in the app's Frameworks")
            return nil
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            SystemUI.log.error("load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let type = (bundle.principalClass ?? NSClassFromString(principalClassName)) as? NSObject.Type else {
            SystemUI.log.error("load failed: no principal class \(principalClassName, privacy: .public)")
            return nil
        }
        guard let provider = type.init() as? any SystemUIProvider else {
            SystemUI.log.error("load failed: \(NSStringFromClass(type), privacy: .public) is not a CMXSystemUIProvider")
            return nil
        }
        let elapsed = ContinuousClock.now - started
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        SystemUI.log.info("loaded ms=\(ms, privacy: .public)")
        return provider
    }
}

// MARK: - Presenting

extension SystemUI {
    /// The scene the person is using: the foreground-active window scene,
    /// else any foreground one.
    @MainActor
    public static var foregroundScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// The topmost controller still on screen in ``foregroundScene``'s key
    /// window, to present from.
    @MainActor
    public static func topViewController() -> UIViewController? {
        guard let scene = foregroundScene,
              let window = scene.keyWindow ?? scene.windows.first(where: { !$0.isHidden }) else { return nil }
        return topmost(from: window.rootViewController)
    }

    @MainActor
    static func topmost(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

// MARK: - Photos

/// One picked photo or video. Its loads run off the main actor.
public struct SystemPhotoPick: Sendable {
    /// The provider, behind a lock so the pick is Sendable: NSItemProvider's
    /// loads are thread-safe, and the provider never changes after the pick.
    private let provider: OSAllocatedUnfairLock<NSItemProvider>
    public let assetIdentifier: String?

    public init(_ pick: any SystemUIPhotoPick) {
        provider = OSAllocatedUnfairLock(uncheckedState: pick.itemProvider)
        assetIdentifier = pick.assetIdentifier
    }

    public var itemProvider: NSItemProvider { provider.withLockUnchecked { $0 } }

    /// The item's types, best first (as `PhotosPickerItem.supportedContentTypes`).
    public var contentTypes: [UTType] {
        itemProvider.registeredTypeIdentifiers.compactMap { UTType($0) }
    }

    public var isMovie: Bool { contentTypes.contains { $0.conforms(to: .movie) } }

    /// The image's data in its best type (the original HEIC or JPEG), as
    /// `PhotosPickerItem.loadTransferable(type: Data.self)` gives it.
    public nonisolated func loadData() async -> Data? {
        let type = contentTypes.first { $0.conforms(to: .image) } ?? contentTypes.first ?? .image
        let provider = itemProvider
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The item as a file conforming to `type`, passed to `copy` while it
    /// exists (the provider deletes it after), as a `FileRepresentation`'s
    /// importer gets it. Nil when it would not load or `copy` threw.
    public nonisolated func loadFile<T: Sendable>(
        conformingTo type: UTType,
        copy: @escaping @Sendable (URL) throws -> T
    ) async -> T? {
        let identifier = contentTypes.first { $0.conforms(to: type) }?.identifier ?? type.identifier
        let provider = itemProvider
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? copy($0) })
            }
        }
    }
}

extension SystemPhotoPick {
    /// ``loadData()`` with the provider's `Progress` (to cancel it, or to see
    /// it stall), as `PhotosPickerItem.loadTransferable(type:completionHandler:)`.
    public nonisolated func loadData(
        completion: @escaping @Sendable (Result<Data?, any Error>) -> Void
    ) -> Progress {
        let type = contentTypes.first { $0.conforms(to: .image) } ?? contentTypes.first ?? .image
        return itemProvider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            if let error, data == nil {
                completion(.failure(error))
            } else {
                completion(.success(data))
            }
        }
    }

    /// ``loadFile(conformingTo:copy:)`` with the provider's `Progress`; a
    /// throwing `copy` fails the load with its error.
    public nonisolated func loadFile<T: Sendable>(
        conformingTo type: UTType,
        copy: @escaping @Sendable (URL) throws -> T,
        completion: @escaping @Sendable (Result<T?, any Error>) -> Void
    ) -> Progress {
        let identifier = contentTypes.first { $0.conforms(to: type) }?.identifier ?? type.identifier
        return itemProvider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
            guard let url else {
                completion(error.map { .failure($0) } ?? .success(nil))
                return
            }
            completion(Result(catching: { try copy(url) }).map { Optional.some($0) })
        }
    }
}

extension SystemUI {
    /// Presents the system photo picker as a sheet over ``topViewController()``
    /// (or `presenter`), dismisses it on Add or Cancel and passes the picks
    /// (none for Cancel or a swipe down). False when the framework did not
    /// load or nothing could present it.
    @MainActor
    @discardableResult
    public static func presentPhotoPicker(
        from presenter: UIViewController? = nil,
        filter: SystemUIPhotoFilter,
        selectionLimit: Int,
        selection: SystemUIPhotoSelection = .standard,
        encoding: SystemUIPhotoEncoding = .automatic,
        onPick: @escaping @MainActor ([SystemPhotoPick]) -> Void
    ) -> Bool {
        guard let provider, let host = topmost(from: presenter) ?? topViewController() else { return false }
        var picker: (any SystemUIPhotoPicker)?
        picker = provider.makePhotoPicker(
            filter: filter,
            selectionLimit: selectionLimit,
            selection: selection,
            encoding: encoding,
            photoLibrary: false,
            preselectedAssetIdentifiers: [],
            onPick: { picks in
                // main-proof: the contract runs onPick on main (PHPickerViewControllerDelegate's didFinishPicking).
                MainActor.assumeIsolated {
                    if let controller = picker?.viewController, controller.presentingViewController != nil {
                        controller.dismiss(animated: true)
                    }
                    picker = nil
                    onPick(picks.map(SystemPhotoPick.init))
                }
            }
        )
        guard let controller = picker?.viewController else { return false }
        host.present(controller, animated: true)
        return true
    }
}

extension View {
    /// The system photo picker as a sheet while `isPresented`, in place of
    /// SwiftUI's `photosPicker` (which links PhotosUI at launch). `onPick` gets
    /// the picks when the person taps Add; Cancel and a swipe down pass none.
    /// `isPresented` resets when the picker closes.
    public func systemPhotoPicker(
        isPresented: Binding<Bool>,
        filter: SystemUIPhotoFilter,
        selectionLimit: Int,
        selection: SystemUIPhotoSelection = .standard,
        encoding: SystemUIPhotoEncoding = .automatic,
        onPick: @escaping @MainActor ([SystemPhotoPick]) -> Void
    ) -> some View {
        background(
            SystemPhotoPickerAnchor(
                isPresented: isPresented,
                filter: filter,
                selectionLimit: selectionLimit,
                selection: selection,
                encoding: encoding,
                onPick: onPick
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}

/// A zero-size controller in the view's hierarchy that presents the picker.
private struct SystemPhotoPickerAnchor: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let filter: SystemUIPhotoFilter
    let selectionLimit: Int
    let selection: SystemUIPhotoSelection
    let encoding: SystemUIPhotoEncoding
    let onPick: @MainActor ([SystemPhotoPick]) -> Void

    final class Coordinator {
        /// The picker on screen (or on its way).
        var presented: UIViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented, coordinator.presented == nil {
            present(from: anchor, coordinator: coordinator)
        } else if !isPresented, let presented = coordinator.presented {
            coordinator.presented = nil
            if presented.presentingViewController != nil { presented.dismiss(animated: true) }
        }
    }

    private func present(from anchor: UIViewController, coordinator: Coordinator) {
        let isPresented = $isPresented
        let onPick = onPick
        guard let provider = SystemUI.provider,
              let host = SystemUI.topmost(from: anchor.viewIfLoaded?.window != nil ? anchor : nil) ?? SystemUI.topViewController() else {
            SystemUI.log.error("photo picker not shown: no framework or nothing to present from")
            // A frame later: SwiftUI refuses a state change inside an update.
            DispatchQueue.main.async { isPresented.wrappedValue = false }
            return
        }
        let picker = provider.makePhotoPicker(
            filter: filter,
            selectionLimit: selectionLimit,
            selection: selection,
            encoding: encoding,
            photoLibrary: false,
            preselectedAssetIdentifiers: [],
            onPick: { [weak coordinator] picks in
                // main-proof: the contract runs onPick on main (PHPickerViewControllerDelegate's didFinishPicking).
                MainActor.assumeIsolated {
                    if let presented = coordinator?.presented {
                        coordinator?.presented = nil
                        if presented.presentingViewController != nil { presented.dismiss(animated: true) }
                    }
                    isPresented.wrappedValue = false
                    onPick(picks.map(SystemPhotoPick.init))
                }
            }
        )
        coordinator.presented = picker.viewController
        host.present(picker.viewController, animated: true)
    }
}

// MARK: - Safari

/// A web page in a Safari view (the person's passkeys, AutoFill and cookies),
/// for a sheet. Without the framework it opens the page in Safari and closes.
public struct SystemSafariView: UIViewControllerRepresentable {
    public let url: URL
    public let entersReaderIfAvailable: Bool

    public init(url: URL, entersReaderIfAvailable: Bool = false) {
        self.url = url
        self.entersReaderIfAvailable = entersReaderIfAvailable
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        if let provider = SystemUI.provider {
            return provider.makeSafariController(url: url, entersReaderIfAvailable: entersReaderIfAvailable)
        }
        return SystemSafariFallbackController(url: url)
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// Opens the page in Safari, then closes the sheet it is in.
private final class SystemSafariFallbackController: UIViewController {
    private let url: URL
    private var opened = false

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !opened else { return }
        opened = true
        UIApplication.shared.open(url)
        (presentingViewController ?? parent?.presentingViewController)?.dismiss(animated: true)
    }
}

extension SystemUI {
    /// A Safari view for `url`, or nil without the framework.
    @MainActor
    public static func safariController(url: URL, entersReaderIfAvailable: Bool = false) -> UIViewController? {
        provider?.makeSafariController(url: url, entersReaderIfAvailable: entersReaderIfAvailable)
    }
}

// MARK: - QuickLook

extension SystemUI {
    /// Whether QuickLook can preview the file; false without the framework.
    @MainActor
    public static func canPreview(_ url: URL) -> Bool {
        provider?.canPreview(url) ?? false
    }
}
#endif
