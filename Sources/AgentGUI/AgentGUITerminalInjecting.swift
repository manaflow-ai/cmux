import Foundation

@MainActor
protocol AgentGUITerminalInjecting: AnyObject {
    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult
    func sendKey(surfaceID: String, keyName: String) -> AgentGUITerminalInjectionResult
    func sendInput(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult
}
