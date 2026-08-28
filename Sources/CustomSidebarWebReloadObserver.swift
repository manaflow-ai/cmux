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
///
/// ## Why the answer is published rather than computed on demand
///
/// Deciding what a name mounts as is filesystem work: probing four candidate extensions, and for a
/// `.url` file reading its bytes to find the page it names. None of that may happen on the main
/// actor, and least of all inside a SwiftUI `body` — the custom sidebar re-renders about once a
/// second, so a read from `body` is a per-second main-thread stall that grows with the size of the
/// user's sidebars directory.
///
/// So the observer owns a single resolution pipeline: requests go in, the filesystem work runs off
/// the main thread, and the finished ``mountDecision`` is published back. A view reads a value that
/// is already decided. Requests are served one at a time and in order by a single consumer, so the
/// last request's answer is the one that survives — which is why this needs no lock and no queue of
/// its own.
@MainActor
@Observable
public final class CustomSidebarWebReloadObserver {
    /// The sidebar name this observer answers for.
    public let sidebarName: String

    /// The file the name currently resolves to, re-read on every reload request.
    ///
    /// `nil` when the name resolves to nothing, which is what a deleted sidebar looks like — and is
    /// also the value before the first resolution lands, so read ``mountDecision`` to tell those
    /// apart.
    public private(set) var resolvedFileURL: URL?

    /// What the sidebar should currently be mounted as.
    ///
    /// `nil` until the first resolution lands. A caller renders nothing for that moment rather than
    /// guessing, because the alternatives are both wrong: an error state flashes on every healthy
    /// mount, and the interpreter is the lane a rejected web source must never reach.
    public private(set) var mountDecision: CustomSidebarMountDecision?

    /// Bumped on every reload request, so an unchanged source still re-fetches.
    ///
    /// Bumped together with the re-resolved ``mountDecision``, in one update. Bumping earlier would
    /// re-fetch the file that is about to lose, then fetch the winner — two loads, and a visible
    /// flash of the old page — for one `cmux sidebar reload`.
    public private(set) var reloadToken = CustomSidebarWebReloadToken.initial

    /// The source the resolved file currently mounts as, or `nil` when it is not a web sidebar.
    ///
    /// Reading through the shared decision is what lets a surface follow a precedence flip: after
    /// `board.swift` appears this returns `nil`, and the mount falls back to the interpreter.
    public var webSource: CustomSidebarWebSource? {
        guard case let .web(source) = mountDecision else { return nil }
        return source
    }

    private let requestContinuation: AsyncStream<ResolutionRequest>.Continuation
    private var observer: (any NSObjectProtocol)?

    /// Creates an observer for one sidebar name.
    ///
    /// - Parameters:
    ///   - sidebarName: The sidebar to answer reload requests for.
    ///   - fallbackFileURL: The file to mount while the name resolves to nothing. A Dock pane passes
    ///     the file it was opened on, because a sidebar being edited in place is briefly absent from
    ///     disk and blanking the pane for that moment is worse than showing what it had. The
    ///     workspace rail passes `nil`: it is switched away entirely when its sidebar stops
    ///     resolving, so a stale mount there would outlive the selection.
    ///   - resolveFileURL: Maps the name to the file that currently wins. Injected so the resolution
    ///     order stays owned by one place and a test can drive a changing filesystem. Its explicit
    ///     `@concurrent` isolation keeps it off the caller's actor, so it must not touch main-actor
    ///     state.
    public init(
        sidebarName: String,
        fallbackFileURL: URL? = nil,
        resolveFileURL: @escaping @concurrent @Sendable (String) async -> URL?
    ) {
        self.sidebarName = sidebarName
        // A pane knows its file before anything is resolved, so when that file's kind follows from
        // its extension alone the first frame is correct with no filesystem work at all. A `.url`
        // fallback still waits: its bytes name the page, and guessing at them is how an unloadable
        // target reaches a renderer.
        mountDecision = fallbackFileURL.flatMap(CustomSidebarMountDecision.decidedWithoutReading(fileURL:))

        let (requests, continuation) = AsyncStream<ResolutionRequest>.makeStream()
        requestContinuation = continuation

        Task { @MainActor [weak self] in
            // Serial by construction: each request's filesystem work is awaited before the next is
            // taken, so outcomes land in request order and the newest is the one left standing.
            for await request in requests {
                let outcome = await Self.resolve(
                    sidebarName: sidebarName,
                    fallbackFileURL: fallbackFileURL,
                    resolveFileURL: resolveFileURL
                )
                self?.apply(outcome, bumpsReloadToken: request.bumpsReloadToken)
                // Resumed after applying, so a waiter observes the settled state rather than
                // racing it. Resumed even when the observer is gone, since an unresumed
                // continuation is a permanent hang rather than a missed update.
                request.settled?.resume()
            }
        }

        continuation.yield(ResolutionRequest(bumpsReloadToken: false))
    }

    deinit {
        // Ends the consumer loop. The task holds no strong reference back, so finishing the stream
        // is all that is needed to let it retire; `observer` is main-actor isolated and `deinit` is
        // not, so unregistration stays with the view that paired `start()` with `stop()`.
        requestContinuation.finish()
    }

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
    /// Returns as soon as the request is queued. The filesystem work happens off the main thread and
    /// lands in ``mountDecision`` and ``reloadToken`` together; ``resolutionSettled()`` waits for
    /// that point.
    ///
    /// - Parameter names: The requested sidebar names, or `nil` for all.
    public func requestReload(names: [String]?) {
        if let names, !names.isEmpty, !names.contains(sidebarName) { return }
        requestContinuation.yield(ResolutionRequest(bumpsReloadToken: true))
    }

    /// Waits until every request queued so far has been applied.
    ///
    /// Exists for tests and for callers that must observe a settled answer rather than the state
    /// mid-flight. Ordinary rendering never needs it: the published state drives the view.
    public func resolutionSettled() async {
        // A request queued behind everything outstanding is applied last, so its landing means the
        // ones before it already landed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestContinuation.yield(ResolutionRequest(bumpsReloadToken: false, settled: continuation))
        }
    }

    private func apply(_ outcome: ResolutionOutcome, bumpsReloadToken: Bool) {
        resolvedFileURL = outcome.resolvedFileURL
        mountDecision = outcome.mountDecision
        if bumpsReloadToken {
            reloadToken = reloadToken.bumped()
        }
    }

    /// Resolves the name and decides the mount, doing the filesystem work off the main thread.
    ///
    /// This function is itself main-actor isolated: it is a static member of a `@MainActor` type, so
    /// its own body runs on the main thread. Nothing it does there blocks. The I/O lives entirely in
    /// the two calls it awaits, and suspending at those awaits is what frees the main thread; the
    /// isolation of this function is not what achieves it.
    ///
    /// Both filesystem boundaries say so explicitly rather than relying on nonisolated-async
    /// inference: the injected lookup's function type is `@concurrent`, and
    /// ``CustomSidebarSource/classifying(fileURL:)`` — reached through
    /// ``CustomSidebarMountDecision/deciding(fileURL:)`` — carries the same annotation for the `.url`
    /// file read.
    private static func resolve(
        sidebarName: String,
        fallbackFileURL: URL?,
        resolveFileURL: @concurrent @Sendable (String) async -> URL?
    ) async -> ResolutionOutcome {
        let resolved = await resolveFileURL(sidebarName)
        let decision = await CustomSidebarMountDecision.deciding(fileURL: resolved ?? fallbackFileURL)
        return ResolutionOutcome(resolvedFileURL: resolved, mountDecision: decision)
    }

    private struct ResolutionRequest {
        var bumpsReloadToken: Bool
        var settled: CheckedContinuation<Void, Never>?
    }

    private struct ResolutionOutcome {
        var resolvedFileURL: URL?
        var mountDecision: CustomSidebarMountDecision
    }
}
