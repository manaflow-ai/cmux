#if canImport(UIKit)
import Foundation
public import Observation

/// Lazily constructs and caches the process's one ``GhosttyEngineService``.
///
/// Built once at the app composition root and injected (via init or the
/// SwiftUI environment) into every view that mounts a terminal surface —
/// replacing the former `GhosttyRuntime.shared()` reach-in while preserving
/// its laziness: libghostty initializes on the first terminal, not at app
/// launch. A failed initialization is cached and rethrown, matching the old
/// behavior.
///
/// `@Observable` so SwiftUI can carry it with `.environment(_:)` /
/// `@Environment(GhosttyEngineProvider.self)`; it has no observable state.
@MainActor
@Observable
public final class GhosttyEngineProvider {
    /// The surface registry shared by the engine and snapshot consumers.
    public let registry: GhosttySurfaceRegistry
    private let clipboard: GhosttyEngineClipboard
    private var cached: Result<GhosttyEngineService, any Error>?

    /// Creates a provider.
    /// - Parameters:
    ///   - registry: The surface registry the engine routes actions through.
    ///   - clipboard: The system-clipboard seam (defaults to
    ///     `UIPasteboard.general`).
    public init(
        registry: GhosttySurfaceRegistry = GhosttySurfaceRegistry(),
        clipboard: GhosttyEngineClipboard = .uiPasteboard
    ) {
        self.registry = registry
        self.clipboard = clipboard
    }

    /// Returns the engine, constructing it on first use.
    /// - Throws: ``GhosttyEngineError`` when libghostty fails to initialize;
    ///   the failure is cached and rethrown on subsequent calls.
    public func engine() throws -> GhosttyEngineService {
        if let cached {
            return try cached.get()
        }
        let result: Result<GhosttyEngineService, any Error>
        do {
            result = .success(try GhosttyEngineService(registry: registry, clipboard: clipboard))
        } catch {
            result = .failure(error)
        }
        cached = result
        return try result.get()
    }
}
#endif
