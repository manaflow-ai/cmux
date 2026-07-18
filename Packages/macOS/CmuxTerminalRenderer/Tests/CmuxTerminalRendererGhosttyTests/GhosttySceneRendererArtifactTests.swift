internal import Foundation
internal import GhosttySceneRendererKit
internal import Testing

@Suite("Ghostty scene-only artifact", .serialized)
struct GhosttySceneRendererArtifactTests {
    init() throws {
        try #require(
            ghostty_scene_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0
        )
    }

    @Test("empty scene resources reject a missing theme without crashing")
    func emptyResourcesDirectoryIsSafe() throws {
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        load(
            "theme = cmux-scene-missing-\(UUID().uuidString)\n",
            into: config
        )
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        #expect(count > 0)
        let diagnostic = ghostty_config_get_diagnostic(config, 0)
        #expect(String(cString: diagnostic.message).isEmpty == false)
    }

    @Test("resolved custom shader config creates a Metal scene renderer")
    func customShaderCreatesRenderer() throws {
        let shaderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scene-\(UUID().uuidString).glsl")
        try Self.shader.write(to: shaderURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: shaderURL) }

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        load("custom-shader = \(shaderURL.path)\n", into: config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)

        var options = ghostty_scene_renderer_options_s()
        options.config = config
        options.width = 640
        options.height = 400
        options.padding_mode = GHOSTTY_SCENE_RENDERER_PADDING_CONFIG
        options.content_scale = 2
        options.renderer_epoch = 1
        options.terminal_id = UUID().uuid
        options.terminal_epoch = 1
        options.presentation_id = UUID().uuid
        options.presentation_generation = 1
        options.max_scene_bytes = 1 << 20
        options.max_allocation_bytes = 2 << 20

        var status = GHOSTTY_SCENE_RENDERER_SUCCESS
        let renderer = try #require(ghostty_scene_renderer_new(&options, &status))
        #expect(status == GHOSTTY_SCENE_RENDERER_SUCCESS)
        var metrics = ghostty_scene_renderer_metrics_s()
        #expect(
            ghostty_scene_renderer_get_metrics(renderer, &metrics)
                == GHOSTTY_SCENE_RENDERER_SUCCESS
        )
        #expect(metrics.columns > 0)
        #expect(metrics.rows > 0)
        #expect(
            ghostty_scene_renderer_destroy(renderer)
                == GHOSTTY_SCENE_RENDERER_SUCCESS
        )
    }

    private func load(_ snapshot: String, into config: ghostty_config_t) {
        snapshot.utf8CString.withUnsafeBufferPointer { bytes in
            "/__cmux_scene_test__/resolved.conf".withCString { path in
                ghostty_config_load_string(
                    config,
                    bytes.baseAddress,
                    UInt(bytes.count - 1),
                    path
                )
            }
        }
    }

    private static let shader = """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            fragColor = texture2D(iChannel0, uv);
        }
        """
}
