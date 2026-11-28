#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminal
import Foundation

extension GhosttySurfaceRepresentable.Coordinator {
    func scheduleTheme(_ theme: TerminalTheme, generation: UInt64) {
        themeApplicationScheduler.schedule(generation: generation) { [weak surfaceView] in
            surfaceView?.applyTerminalConfigTheme(theme)
        }
    }
}

extension GhosttySurfaceView {
    func seedThemeParityPreviewIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_UITEST_THEME_PARITY_PREVIEW"] == "1" else {
            return
        }
        processOutput(Data("cmux theme parity renderer\r\nvisible terminal content\r\n".utf8))
        #endif
    }
}
#endif
