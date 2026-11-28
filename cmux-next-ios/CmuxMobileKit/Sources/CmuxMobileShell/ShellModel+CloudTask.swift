#if os(iOS)
import CmuxMobileLive
import CmuxMobileModel
import Foundation

/// New Task on a Cloud machine: the machine, through the Mac that lists it, and the first message.
struct CloudChatTask: Hashable {
    let location: CloudChatLocation
    let prompt: String
}

extension ShellModel {
    /// New Task offers the Cloud machines the focused Mac lists beside the Macs; Start opens the
    /// machine's new Claude chat (Cloud chats) with the task as its first message.
    func wireCloudTasks() {
        creator.cloudTaskTargetsSource = { [weak self] in
            guard let live = self?.live else { return nil }
            let link = String(UInt(bitPattern: ObjectIdentifier(live).hashValue))
            guard let macID = live.focusedMacID else { return link }
            return [link, macID, live.canLink(macID: macID) ? "linked" : "unlinked"].joined(separator: "/")
        }
        creator.loadCloudTaskTargets = { [weak self] in
            guard let self, let live = self.live, let macID = live.focusedMacID, live.canLink(macID: macID) else { return nil }
            guard let machines = try? await live.cloudMachines(on: macID) else { return nil }
            return CloudChatDirectory.scopedMachines(machines, attention: nil).map {
                CloudTaskTarget(teamID: $0.teamID, machineID: $0.machineID, name: $0.name, macID: macID)
            }
        }
        creator.openCloudTask = { [weak self] target, prompt in
            guard let self else { return }
            let machine = CloudChatMachine(machineID: target.machineID, teamID: target.teamID, name: target.name)
            cloudChats = CloudChatsPresentation(attention: nil, task: CloudChatTask(
                location: CloudChatLocation(macID: target.macID, machine: machine), prompt: prompt))
        }
        #if DEBUG
        // `-cmux-mobile-mock-cloud-machine`: the Mac lists one Cloud machine and New Task opens on
        // it (its captures and What's New clip; the mock app has no live Mac).
        if CommandLine.arguments.contains("-cmux-mobile-mock-cloud-machine") {
            let box = CloudTaskTarget(teamID: "demo-team", machineID: "demo-box", name: "Build box", macID: "mac-studio")
            creator.loadCloudTaskTargets = { [box] }
            creator.cloudTaskTargets = [box]
            creator.taskDraft.chooseCloud(box.id)
        }
        #endif
    }
}
#endif
