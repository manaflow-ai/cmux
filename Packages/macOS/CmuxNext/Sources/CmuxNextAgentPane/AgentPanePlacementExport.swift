// RightColumnPlacement and AgentSubagentPanes live in CmuxNextAgentPanePlacement, a target without
// AppKit or the daemon (its tests run on Linux); `import CmuxNextAgentPane` still brings them.
@_exported public import CmuxNextAgentPanePlacement
