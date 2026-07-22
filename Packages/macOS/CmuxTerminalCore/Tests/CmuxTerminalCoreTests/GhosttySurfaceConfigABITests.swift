import GhosttyKit
import Testing

@Suite
struct GhosttySurfaceConfigABITests {
    @Test func publicConfigLayoutRemainsStable() {
        #expect(MemoryLayout<ghostty_surface_config_s>.size == 120)
        #expect(MemoryLayout<ghostty_surface_config_s>.stride == 120)
        #expect(MemoryLayout<ghostty_surface_config_s>.alignment == 8)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.platform_tag) == 0)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.platform) == 8)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.userdata) == 16)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.scale_factor) == 24)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.font_size) == 32)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.working_directory) == 40)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.command) == 48)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.env_vars) == 56)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.env_var_count) == 64)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.initial_input) == 72)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.wait_after_command) == 80)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.context) == 84)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_mode) == 88)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_write_cb) == 96)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.io_write_userdata) == 104)
        #expect(MemoryLayout<ghostty_surface_config_s>.offset(of: \.renderer_event_cb) == 112)
    }
}
