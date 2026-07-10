import Testing
@testable import CmuxSettingsUI

@Suite("SettingsRuntime")
struct SettingsRuntimeTests {
    @Test func valueHandleIsPointerSized() {
        #expect(
            MemoryLayout<SettingsRuntime>.size == MemoryLayout<UnsafeRawPointer>.size,
            "SettingsRuntime is copied through every @Environment-backed LiveSetting and must remain a cheap value handle"
        )
    }
}
