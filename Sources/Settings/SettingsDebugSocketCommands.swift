import AppKit

#if DEBUG
extension TerminalController {
    func v2DebugSettingsWindowState(params: [String: Any]) -> TerminalController.V2CallResult {
        let window = NSApp.windows.first { $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier }
        let frame = window?.frame ?? .zero
        if params["close"] as? Bool == true {
            window?.close()
        }
        return .ok([
            "exists": window != nil,
            "identifier": window?.identifier?.rawValue ?? NSNull(),
            "visible": window?.isVisible ?? false,
            "miniaturized": window?.isMiniaturized ?? false,
            "main": NSApp.mainWindow === window,
            "key": NSApp.keyWindow === window,
            "width": Int(frame.width.rounded()),
            "height": Int(frame.height.rounded())
        ])
    }
}
#endif
