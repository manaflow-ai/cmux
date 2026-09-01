import Foundation

/// A structural config error that can be reported without importing the app's
/// AppKit-backed config model. The CLI and the published JSON Schema use the
/// same shape checks for the sections that contain executable actions.
struct CmuxConfigValidationIssue: Equatable, Sendable, CustomStringConvertible {
    /// Keep diagnostic details stable and English: this Foundation-only value is
    /// shared by the CLI and app, while each presentation surface localizes its
    /// surrounding report text without translating paths or schema tokens.
    let path: String
    let message: String

    var description: String {
        path + ": " + message
    }
}

/// Canonical identifiers and legacy aliases accepted by config decoding.
///
/// The CLI validator and the app's Codable action model both use this table so
/// adding an alias cannot make doctor and runtime disagree about duplicates or
/// unknown built-ins.
struct CmuxConfigBuiltInActionCatalog: Sendable {
    private let canonicalIDs: [String: String]

    init(canonicalIDs: [String: String]) {
        self.canonicalIDs = canonicalIDs
    }

    init() {
        self.init(canonicalIDs: [
            "cmux.newWorkspace": "cmux.newWorkspace",
            "newWorkspace": "cmux.newWorkspace",
            "cmux.newAgentChat": "cmux.newAgentChat",
            "cmux.agentChat": "cmux.newAgentChat",
            "newAgentChat": "cmux.newAgentChat",
            "new-agent-chat": "cmux.newAgentChat",
            "agentChat": "cmux.newAgentChat",
            "cmux.cloudvm": "cmux.cloudvm",
            "cmux.cloudVM": "cmux.cloudvm",
            "cloudVM": "cmux.cloudvm",
            "cloudvm": "cmux.cloudvm",
            "cmux.newCloudVM": "cmux.cloudvm",
            "cmux.newCloudVm": "cmux.cloudvm",
            "newCloudVM": "cmux.cloudvm",
            "newCloudVm": "cmux.cloudvm",
            "cmux.startCloudVM": "cmux.cloudvm",
            "cmux.startCloudVm": "cmux.cloudvm",
            "startCloudVM": "cmux.cloudvm",
            "startCloudVm": "cmux.cloudvm",
            "cmux.mobileconnect": "cmux.mobileconnect",
            "cmux.mobileConnect": "cmux.mobileconnect",
            "mobileConnect": "cmux.mobileconnect",
            "mobileconnect": "cmux.mobileconnect",
            "cmux.connectPhone": "cmux.mobileconnect",
            "connectPhone": "cmux.mobileconnect",
            "cmux.newTerminal": "cmux.newTerminal",
            "newTerminal": "cmux.newTerminal",
            "cmux.newBrowser": "cmux.newBrowser",
            "newBrowser": "cmux.newBrowser",
            "cmux.newSimulator": "cmux.newSimulator",
            "newSimulator": "cmux.newSimulator",
            "new-simulator": "cmux.newSimulator",
            "simulator": "cmux.newSimulator",
            "cmux.splitRight": "cmux.splitRight",
            "splitRight": "cmux.splitRight",
            "cmux.splitDown": "cmux.splitDown",
            "splitDown": "cmux.splitDown",
        ])
    }

    func canonicalID(for rawID: String) -> String? {
        canonicalIDs[rawID]
    }
}
