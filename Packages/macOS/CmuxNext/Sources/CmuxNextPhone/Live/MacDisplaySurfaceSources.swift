import CmuxNextCompat
public import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

/// This Mac's own screen as a phone's streamed surface, view only: hostd's `surface` tab
/// `d~<CGDirectDisplayID>` (`0` is the main display; cmux-mobile-host `surface.rs`). The phone
/// gets the screen as `cmux.rd/1` on the link it already holds to this Mac (cmux-wg), the same
/// stream a Cloud desktop tab uses, instead of a WebRTC session through the device hub.
///
/// One ``CloudDesktopSurfaceServer`` per tab, with frames from the app's display feed. The app's
/// `grant` decides each start: it refuses while Share This Mac is off, or when the process that
/// captures has no Screen Recording grant, and hands back the feed and a liveness check (Share
/// This Mac still on). A source stops when that check turns false, its capture ends, or hostd
/// stops it. hostd forwards no phone input to a `d~` source, and the server drops any that came.
@MainActor
public final class MacDisplaySurfaceSources {
    public enum Failure: Error, Sendable, CustomStringConvertible, Equatable {
        case notMacDisplay, notShared, noScreenRecording(String), noDisplay

        public var description: String {
            switch self {
            case .notMacDisplay: "that tab is not one of this Mac's displays"
            case .notShared: "Share This Mac is off on this Mac"
            case .noScreenRecording(let why): "this Mac cannot capture its screen for the iPhone: \(why)"
            case .noDisplay: "that display is not connected to this Mac"
            }
        }
    }

    /// The display a `d~<id>` tab names: its `CGDirectDisplayID`, `0` for the main display; nil for
    /// anything else (a decimal `UInt32`, no sign, no leading zeros but `0` itself).
    public nonisolated static func display(of tab: String) -> UInt32? {
        guard tab.hasPrefix("d~") else { return nil }
        let digits = tab.dropFirst(2)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits == "0" || digits.first != "0" else { return nil }
        return UInt32(digits)
    }

    /// The most pixels on a captured picture's long edge: the encoder's own limit, so a capture never
    /// makes pixels the encoder scales away.
    public nonisolated static let maximumLongEdge = SurfaceFrameEncoder.maximumLongSide

    /// The `surface` tab key of a display.
    public nonisolated static func tab(display: UInt32) -> String { "d~\(display)" }

    private let grant: @MainActor (UInt32) async throws -> CloudDesktopSurfaceSources.Grant
    private var running: [String: (server: CloudDesktopSurfaceServer, watch: Task<Void, Never>)] = [:]

    public init(grant: @escaping @MainActor (UInt32) async throws -> CloudDesktopSurfaceSources.Grant) {
        self.grant = grant
    }

    /// Sources granted while `sharing` (Share This Mac) reads true, each with the feed `capture` makes
    /// for the display (it throws why it cannot capture it), stopped once `sharing` turns false.
    public convenience init(sharing: @escaping @MainActor () -> Bool, capture: @escaping @MainActor (UInt32) throws -> SurfaceFrameFeed) {
        self.init { display in
            guard sharing() else { throw Failure.notShared }
            return CloudDesktopSurfaceSources.Grant(feed: try capture(display), label: "display \(display)", stillLive: sharing)
        }
    }

    public func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        guard let display = Self.display(of: tab) else { throw Failure.notMacDisplay }
        let granted = try await grant(display)
        guard granted.stillLive() else { throw Failure.notShared }
        stop(tab: tab)
        let server = CloudDesktopSurfaceServer(feed: granted.feed, label: granted.label)
        server.onEnd = { [weak self, weak server] in
            if let server, let entry = self?.running[tab], entry.server === server {
                entry.watch.cancel()
                self?.running[tab] = nil
            }
            onExit()
        }
        let stillLive = granted.stillLive
        let live = ObservationStream { stillLive() }
        // task-owner: the source's liveness watch (Share This Mac on); cancelled when the source ends or is stopped
        let watch = Task { [weak server] in
            for await isLive in live where !isLive {
                server?.stop()
                return
            }
        }
        // Recorded before the start's await: a stop meanwhile stops this server and the start fails.
        running[tab] = (server, watch)
        do {
            let port = try await server.start()
            guard server.isRunning, running[tab]?.server === server else { throw Failure.notShared }
            logger.info("mac display source \(granted.label, privacy: .public) on port \(port, privacy: .public)")
            return (port, server.secret)
        } catch {
            watch.cancel()
            if running[tab]?.server === server { running[tab] = nil }
            server.onEnd = nil
            server.stop()
            throw error
        }
    }

    public func stop(tab: String) {
        guard let entry = running.removeValue(forKey: tab) else { return }
        entry.watch.cancel()
        entry.server.stop()
    }

    public func stopAll() {
        let all = running.values
        running = [:]
        for entry in all {
            entry.watch.cancel()
            entry.server.stop()
        }
    }

    /// Tabs with a running source (tests and diagnostics).
    public var runningTabs: [String] { running.keys.sorted() }
}
