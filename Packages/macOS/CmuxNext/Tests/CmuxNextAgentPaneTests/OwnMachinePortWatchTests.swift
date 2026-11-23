import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

struct OwnMachinePortWatchTests {
    typealias Listener = MachineListeningTCPRequest.Listener

    @Test func theFirstReadIsABaselineNoCardShows() {
        let changes = OwnMachinePortWatch.changes(machineID: "server-mini", before: nil, now: [Listener(port: 5173, process: "node")])
        #expect(changes == [CloudPortChange(machineID: "server-mini", port: 5173, proto: "tcp", process: "node", state: .opened, known: true)])
    }

    @Test func aNewDevServerOpensAndAStoppedOneCloses() {
        let changes = OwnMachinePortWatch.changes(machineID: "ssh-box", before: [3000, 8080],
                                                  now: [Listener(port: 3000), Listener(port: 5173, process: "vite")])
        #expect(changes == [
            CloudPortChange(machineID: "ssh-box", port: 5173, proto: "tcp", process: "vite", state: .opened, known: false),
            CloudPortChange(machineID: "ssh-box", port: 8080, proto: "tcp", process: nil, state: .closed),
        ])
    }

    @Test func nothingChangedSaysNothing() {
        #expect(OwnMachinePortWatch.changes(machineID: "ssh-box", before: [3000], now: [Listener(port: 3000)]).isEmpty)
    }

    @Test func theDaemonsPortsDecodeAndAnOlderDaemonHasNone() throws {
        let new = try JSONDecoder().decode(MachineListeningTCPRequest.Response.self,
                                           from: Data(#"{"stdout":"x","ports":[{"port":5173,"process":"node"},{"port":8000}]}"#.utf8))
        #expect(new.ports == [Listener(port: 5173, process: "node"), Listener(port: 8000)])
        let old = try JSONDecoder().decode(MachineListeningTCPRequest.Response.self, from: Data(#"{"stdout":"x"}"#.utf8))
        #expect(old.ports == nil)
    }
}
