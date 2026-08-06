import CmuxFoundation
import CmuxSidebar
import CmuxSwiftRenderUI
import Foundation
import Observation

/// Turns `cmux sidebar reload` into a re-fetch for a hosted web sidebar, and re-resolves which file
/// that sidebar is.
///
/// Interpreted sidebars already answer the reload notification through `CustomSidebarModel`. A web
/// sidebar has no model — the page is its own renderer — so nothing was listening, and
/// `cmux sidebar reload board` on an HTML sidebar did nothing at all.
///
/// Re-resolution matters as much as the re-fetch. A name maps to a file through the shared
/// extension order, and that mapping can change under a live sidebar: adding `board.swift` beside
/// `board.html` promotes the interpreted file, and deleting the interpreted file demotes back to the
/// web one. A surface that captured its file once keeps rendering the file that no longer wins,
/// which reads as "reload did nothing" for as long as the surface lives.
@MainActor
@Observable
public final class CustomSidebarWebReloadObserver {
    /// The sidebar name this observer answers for.
    public let sidebarName: String

    /// The file the name currently resolves to, re-read on every reload request.
    ///
    /// `nil` when the name resolves to nothing, which is what a deleted sidebar looks like.
    public private(set) var resolvedFileURL: URL?

    /// Bumped on every reload request, so an unchanged source still re-fetches.
    public private(set) var reloadToken = CustomSidebarWebReloadToken.initial

    private let resolveFileURL: @MainActor (String) -> URL?
    private var observer: (any NSObjectProtocol)?

    /// Creates an observer for one sidebar name.
    ///
    /// - Parameters:
    ///   - sidebarName: The sidebar to answer reload requests for.
    ///   - resolveFileURL: Maps the name to the file that currently wins. Injected so the resolution
    ///     order stays owned by one place and a test can drive a changing filesystem.
    public init(
        sidebarName: String,
        resolveFileURL: @escaping @MainActor (String) -> URL?
    ) {
        self.sidebarName = sidebarName
        self.resolveFileURL = resolveFileURL
        resolvedFileURL = resolveFileURL(sidebarName)
    }

    // No `deinit` unregistration: `observer` is main-actor isolated and `deinit` is not, so the
    // read is not expressible. Registration is instead owned by the view that starts it, which
    // pairs `start()` with `stop()` across appear/disappear.

    /// Starts answering reload notifications. Idempotent.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .customSidebarReloadRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let names = notification.userInfo?["names"] as? [String]
            MainActor.assumeIsolated {
                self?.requestReload(names: names)
            }
        }
    }

    /// Stops answering reload notifications. Safe to call repeatedly.
    public func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    /// Re-resolves and re-fetches when `names` is absent/empty or names this sidebar.
    ///
    /// Matches ``CustomSidebarModel``'s filter exactly, so `cmux sidebar reload` with no name
    /// reloads web and interpreted sidebars alike rather than half of them.
    ///
    /// - Parameter names: The requested sidebar names, or `nil` for all.
    public func requestReload(names: [String]?) {
        if let names, !names.isEmpty, !names.contains(sidebarName) { return }
        resolvedFileURL = resolveFileURL(sidebarName)
        reloadToken = reloadToken.bumped()
    }

    /// The source the resolved file currently classifies as, or `nil` when it is not a web sidebar.
    ///
    /// Reading through the shared classifier is what lets a surface follow a precedence flip: after
    /// `board.swift` appears this returns `nil`, and the mount falls back to the interpreter.
    public var webSource: CustomSidebarWebSource? {
        guard let resolvedFileURL,
              case let .web(source) = CustomSidebarSource.classify(fileURL: resolvedFileURL)
        else { return nil }
        return source
    }
}
