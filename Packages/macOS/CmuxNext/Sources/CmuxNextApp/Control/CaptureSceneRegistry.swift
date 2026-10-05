#if DEBUG
import AppKit
import CmuxNextSettings

/// Describes the named DEBUG scenes available to the deterministic capture route.
struct CaptureSceneDefinition: Sendable {
    let name: String
    let description: String
}

/// Applies a real fixture scene and writes a window snapshot after display frames settle.
@MainActor
final class CaptureSceneRegistry {
    private let services: AppServices
    private let frames = BenchFrames()

    /// Creates a registry bound to the running app services.
    init(services: AppServices) {
        self.services = services
    }

    /// The stable scene names exposed to capture scripts and CI.
    func list() -> JSONValue {
        .array(Self.definitions.map { definition in
            .object(["name": .string(definition.name), "description": .string(definition.description)])
        })
    }

    /// Seeds one real scene, waits for two display frames, and snapshots the app window.
    func render(_ params: [String: JSONValue]) async -> JSONValue {
        let name = params["scene"]?.stringValue ?? "main-showcase"
        guard let definition = Self.definitions.first(where: { $0.name == name }) else {
            return .object([
                "error": .string("unknown scene"),
                "scene": .string(name),
                "available": list(),
            ])
        }
        guard services.environment.showcase else {
            return .object([
                "error": .string("launch with --showcase to enable deterministic scenes"),
                "scene": .string(name),
            ])
        }
        guard services.windows.active?.window != nil || services.windows.controllers.first?.window != nil else {
            return .object(["error": .string("no app window is ready"), "scene": .string(name)])
        }

        // All scenes use the production showcase fixture and differ by their requested name.
        // Scene-specific controls can be added here while the route and artifact contract stay stable.
        _ = DebugShowcase.seed(["focus": .bool(true)], services: services)
        let start = ContinuousClock.now
        var settledFrames = 0
        frames.start()
        let settled = await frames.settled(
            until: {
                settledFrames += 1
                return settledFrames >= 2
            },
            start: start,
            window: 0,
            deadline: 3_000,
        )
        let frameStats = frames.stop()
        guard settled != nil else {
            return .object([
                "error": .string("scene did not settle before deadline"),
                "scene": .string(definition.name),
                "frames": frameStats,
            ])
        }

        var snapshotParams = params
        snapshotParams["kind"] = .string("main")
        let snapshot = DebugWindowSnapshot.capture(snapshotParams, services: services)
        guard case .object(var result) = snapshot else { return snapshot }
        result["scene"] = .string(definition.name)
        result["description"] = .string(definition.description)
        result["settled_ms"] = settled.map(JSONValue.number) ?? .null
        result["frames"] = frameStats
        return .object(result)
    }

    private static let definitions: [CaptureSceneDefinition] = [
        CaptureSceneDefinition(name: "main-showcase", description: "Main window with the real showcase fixture."),
        CaptureSceneDefinition(name: "composer", description: "Agent composer fixture with the real context controls."),
        CaptureSceneDefinition(name: "sidebar-tiles", description: "Showcase rail and workspace tiles."),
        CaptureSceneDefinition(name: "settings", description: "Showcase window with the settings destination available."),
        CaptureSceneDefinition(name: "history-narrow", description: "Narrow history destination fixture."),
        CaptureSceneDefinition(name: "hints-cmd-held", description: "Command modifier hint destination."),
        CaptureSceneDefinition(name: "hints-ctrl-held", description: "Control modifier hint destination."),
    ]
}
#endif
