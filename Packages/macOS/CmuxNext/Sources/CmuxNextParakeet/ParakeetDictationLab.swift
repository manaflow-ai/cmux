public import AppKit
public import CmuxNextDictation
import CmuxNextCompat
import CmuxNextDesign
public import Foundation

/// Labs > Parakeet Dictation (`labs.parakeetDictation`, docs/design/voice-byo-providers.md slice 3):
/// while on, every dictation surface uses ``ParakeetDictationTranscriber`` instead of On This Mac.
/// Turning it on downloads the model once, shown as a progress toast with Cancel and then its size on
/// disk; turning it off cancels a download, frees the model's memory and gives dictation back to On This
/// Mac. The default (off) changes nothing.
///
/// The app makes one when its settings load and calls ``follow(_:)`` with the setting; it lives as long
/// as those settings.
@MainActor
public final class ParakeetDictationLab {
    private static let toastID = "labs.parakeetDictation"
    private let directory: URL
    private let claims: DictationMicrophoneClaims
    private let window: @MainActor () -> NSWindow?
    private var store: ParakeetModelStore?
    private var showsDownload = false
    private var shown: CmuxToastHandle?

    /// - Parameters:
    ///   - directory: The model's folder, in the app's own support folder.
    ///   - claims: Where dictation surfaces read their engine.
    ///   - window: The window the toasts show in.
    public init(directory: URL, claims: DictationMicrophoneClaims = .shared, window: @escaping @MainActor () -> NSWindow?) {
        self.directory = directory
        self.claims = claims
        self.window = window
    }

    /// Follows the setting until `isOn` returns `nil` (its settings are gone); the task keeps this lab.
    public func follow(_ isOn: @escaping @MainActor () -> Bool?) {
        // task-owner: lives as long as the app's settings (ends at nil); event-driven (Observation).
        Task {
            for await on in ObservationStream(isOn) {
                guard let on else { return }
                await apply(on)
            }
        }
    }

    private func apply(_ on: Bool) async {
        guard on else {
            claims.engine = nil
            showsDownload = false
            await store?.unload()
            return
        }
        guard ParakeetModelStore.isSupported else {
            claims.engine = nil
            toast(ParakeetDictationStrings.unsupported, duration: .seconds(6))
            return
        }
        let store = makeStore()
        claims.engine = { meter in ParakeetDictationTranscriber(store: store, levelMeter: meter) }
        // On disk already: the first dictation loads it; nothing to show.
        await store.refresh()
        if case .ready = await store.state { return }
        showsDownload = true
        await store.prepare()
    }

    private func makeStore() -> ParakeetModelStore {
        if let store { return store }
        let made = ParakeetModelStore(directory: directory)
        store = made
        let (states, sink) = AsyncStream<ParakeetModelStore.State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // task-owner: lives as long as this lab (the app's); one state at a time, in order.
        Task { [weak self] in
            await made.observe { sink.yield($0) }
            for await state in states {
                guard let self else { return }
                show(state)
            }
        }
        return made
    }

    private func show(_ state: ParakeetModelStore.State) {
        switch state {
        case .notDownloaded:
            // Cancelled: the toast's Cancel or Esc on a dictation that started the download.
            if showsDownload { shown?.dismiss() }
            showsDownload = false
        case .downloading(let fraction):
            showsDownload = true
            let handle = toast(ParakeetDictationStrings.downloading(percent: Int((fraction * 100).rounded(.down))),
                               duration: .seconds(600), action: ParakeetDictationStrings.cancel, working: true)
            handle?.onAction = { [store] in Task { await store?.cancel() } }
        case .preparing:
            guard showsDownload else { return }
            toast(ParakeetDictationStrings.preparing, duration: .seconds(600), working: true)
        case .ready(let bytes):
            guard showsDownload else { return }
            showsDownload = false
            toast(ParakeetDictationStrings.ready(size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)),
                  duration: .seconds(8))
        case .failed(let reason):
            showsDownload = false
            let handle = toast(ParakeetDictationStrings.failed, detail: reason, duration: .seconds(12),
                               action: ParakeetDictationStrings.retry)
            handle?.onAction = { [store] in Task { await store?.prepare() } }
        }
    }

    @discardableResult
    private func toast(_ message: String, detail: String? = nil, duration: Duration,
                       action: String? = nil, working: Bool = false) -> CmuxToastHandle? {
        guard let window = window() else { return nil }
        shown = CmuxToastCenter.shared.show(CmuxToast(id: Self.toastID, message: message, detail: detail,
                                                     action: action.map { CmuxToast.Action(title: $0) },
                                                     duration: duration, oneWindow: true, working: working), in: window)
        return shown
    }
}

enum ParakeetDictationStrings {
    static func downloading(percent: Int) -> String {
        String(format: String(localized: "parakeetDictation.downloading", defaultValue: "Downloading the Parakeet speech model: %lld%%",
                              table: "Parakeet", bundle: .module.inAppLanguage), percent)
    }

    static var preparing: String {
        String(localized: "parakeetDictation.preparing", defaultValue: "Preparing the Parakeet speech model for this Mac…",
               table: "Parakeet", bundle: .module.inAppLanguage)
    }

    static func ready(size: String) -> String {
        String(format: String(localized: "parakeetDictation.ready", defaultValue: "Parakeet Dictation is ready. The model uses %@ on this Mac.",
                              table: "Parakeet", bundle: .module.inAppLanguage), size)
    }

    static var failed: String {
        String(localized: "parakeetDictation.failed", defaultValue: "The Parakeet speech model did not download.",
               table: "Parakeet", bundle: .module.inAppLanguage)
    }

    static var unsupported: String {
        String(localized: "parakeetDictation.unsupported", defaultValue: "Parakeet Dictation needs a Mac with Apple silicon.",
               table: "Parakeet", bundle: .module.inAppLanguage)
    }

    static var cancel: String {
        String(localized: "parakeetDictation.cancel", defaultValue: "Cancel", table: "Parakeet", bundle: .module.inAppLanguage)
    }

    static var retry: String {
        String(localized: "parakeetDictation.retry", defaultValue: "Try Again", table: "Parakeet", bundle: .module.inAppLanguage)
    }
}
