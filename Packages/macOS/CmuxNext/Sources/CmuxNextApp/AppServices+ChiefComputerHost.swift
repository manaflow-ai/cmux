import CmuxHomeCore
import CmuxNextActions
import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextHostedChief

// The Chief's computer (CmuxNextHostedChief's ChiefComputerWiring and ChiefComputerPages): one-line forwards to the
// App's owners. The machine records, live feed, pointer painter, control source and Open Desktop are in Cloud/AppServices+Cloud.swift.
extension AppServices: ChiefComputerHost {
    func cloudChiefID(_ conversation: String) -> String? { home.cloudChiefs.chief(for: conversation)?.id }
    func chiefDisplayName(_ conversation: String) -> String { home.chiefName(of: ConversationID(conversation)) ?? HomeStrings.chiefName }
    var defaultChiefConversation: String? { home.defaultChiefConversation }
    var cloudPlanID: String? { machines.cloudLimits?.planId }
    var cloudMachinesListed: Bool { machines.cloudLimits != nil }
    func cloudMachineRecord(_ id: String) -> CloudMachine? { machines.session(id)?.machine }
    var computerControl: ChiefComputerControlStore { cloud.computerControl }
    var cloudMachineAPI: CloudAPIClient { cloud.machineAPI }
    var chiefBrainRoute: HomeChiefHostedEngine.Send { home.hostedChief.brainRoute }
    func createCloudMachine(name: String?) async throws -> String { try await cloud.createMachine(name: name, startedByPerson: true).machineID }
    func showChiefSettings() { try? settingsWindow.show(section: nil, focus: true, route: "#/settings/chief") }
    func upgradeToPaidPlan() async { await paidPlanUpgrade().start(plan: "pro", source: .cloudRefusal, fallback: nil) }
    func moveDefaultChiefToCloud() { _ = registry.perform(ChiefMoveHandlers.actionID, invocation: ActionInvocation(arguments: ["target": .string(ChiefMoveTargets.cloudID)], origin: .user)) }
}
