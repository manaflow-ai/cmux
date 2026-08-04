import GhosttyKit
import Testing

@Suite
struct GhosttySurfaceConfigABITests {
    @Test func publicConfigLayoutRemainsStable() {
        #expect(MemoryLayout<ghostty_surface_config_s>.size == 168)
        #expect(MemoryLayout<ghostty_surface_config_s>.stride == 168)
        #expect(MemoryLayout<ghostty_surface_config_s>.alignment == 8)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.platform_tag) == 0)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.platform) == 8)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.userdata) == 48)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.scale_factor) == 56)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.font_size) == 64)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.working_directory) == 72)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.command) == 80)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.env_vars) == 88)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.env_var_count) == 96)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.initial_input) == 104)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.wait_after_command) == 112)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.context) == 116)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_mode) == 120)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_write_cb) == 128)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_write_userdata) == 136)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.renderer_event_cb) == 144)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.pty_tee_cb) == 152)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.pty_tee_userdata) == 160)
    }
}
