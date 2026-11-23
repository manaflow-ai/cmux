import CCmuxLaunchShellFFI
import Foundation

/// One thing to do to a cover (Rust `RevealStep`).
public nonisolated enum RelaunchCoverStep: Decodable, Sendable, Equatable {
    /// Fade out this pane's region of the window's picture.
    case surface(window: String, surface: String, fadeMs: UInt32)
    /// Remove what is left of the window's picture.
    case window(window: String, fadeMs: UInt32)

    enum CodingKeys: String, CodingKey { case step, window, surface, fadeMs }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let window = try values.decode(String.self, forKey: .window)
        let fadeMs = try values.decode(UInt32.self, forKey: .fadeMs)
        if try values.decode(String.self, forKey: .step) == "surface" {
            self = .surface(window: window, surface: try values.decode(String.self, forKey: .surface), fadeMs: fadeMs)
        } else {
            self = .window(window: window, fadeMs: fadeMs)
        }
    }

    public var window: String {
        switch self {
        case .surface(let window, _, _), .window(let window, _): window
        }
    }
}

/// Which panes of each covered window are live (Rust `Reveal`). Each call returns the steps to apply now.
@MainActor
public final class RelaunchCoverReveal {
    /// Rust's `Reveal`, owned here alone; kept as its address so the nonisolated deinit can free it.
    private let address: Int
    private var handle: OpaquePointer? { OpaquePointer(bitPattern: address) }

    public init?(plan: RelaunchCoverPlan, style: RelaunchCoverStyle, openedMs: UInt64) {
        guard plan.shows, let handle = plan.json.withCString({ cmux_relaunch_cover_reveal_new($0, style.rawValue, openedMs) })
        else { return nil }
        address = Int(bitPattern: handle)
    }

    nonisolated deinit { cmux_relaunch_cover_reveal_free(OpaquePointer(bitPattern: address)) }

    /// Windows with no pane to wait for: their covers go at once.
    public func start() -> [RelaunchCoverStep] { Self.steps(cmux_relaunch_cover_reveal_start(handle)) }

    public func surfaceReady(window: String, surface: String, nowMs: UInt64) -> [RelaunchCoverStep] {
        Self.steps(window.withCString { window in surface.withCString { cmux_relaunch_cover_reveal_surface_ready(handle, window, $0, nowMs) } })
    }

    /// The live window does not match its picture: it goes now.
    public func mismatch(window: String) -> [RelaunchCoverStep] {
        Self.steps(window.withCString { cmux_relaunch_cover_reveal_mismatch(handle, $0) })
    }

    /// Past the deadline every cover left goes. `next` is when to call again, nil once every cover is gone.
    public func tick(nowMs: UInt64) -> (steps: [RelaunchCoverStep], next: UInt64?) {
        var next: UInt64 = 0
        let steps = Self.steps(cmux_relaunch_cover_reveal_tick(handle, nowMs, &next))
        return (steps, next == 0 ? nil : next)
    }

    private static func steps(_ pointer: UnsafeMutablePointer<CChar>?) -> [RelaunchCoverStep] {
        guard let raw = RelaunchCoverStore.take(pointer) else { return [] }
        return (try? RelaunchCoverStore.decoder.decode([RelaunchCoverStep].self, from: Data(raw.utf8))) ?? []
    }
}
