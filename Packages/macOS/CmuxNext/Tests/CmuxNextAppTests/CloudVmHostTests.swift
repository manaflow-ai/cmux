import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings > Machines' "Dedicated agent machine" switch on a Cloud machine (acpmux vmHost): the
/// machine's own `acpmux host vm-host` over the Cloud exec, as its work user; what it answers is
/// the switch; page script alone never turns it on.
@MainActor struct CloudVmHostTests {
    @Test func theCommandRunsTheMachinesOwnVmHostAsItsWorkUser() {
        let read = CloudVmHost.command(on: nil)
        #expect(read.hasSuffix(#"as_u env HOME="$h" "$b" acp --json host vm-host"#))
        #expect(CloudVmHost.command(on: true).hasSuffix("host vm-host on"))
        #expect(CloudVmHost.command(on: false).hasSuffix("host vm-host off"))
        #expect(read.contains(#"b="$h/.cmux/bin/cmux-tui""#))
        #expect(read.contains("u=cmux; id -u \"$u\" >/dev/null 2>&1 || u=root"), "an image from before the work user runs it as root")
    }

    @Test func itReadsAcpmuxsPrettyJSONAndItsErrorEnvelope() {
        let on = CloudExecResult(exitCode: 0, stdout: "{\n  \"vmHost\": true,\n  \"cmuxVm\": true,\n  \"configured\": null\n}\n", stderr: "")
        #expect(CloudVmHost.parse(on) == CloudVmHost.State(on: true, cmuxVM: true))
        let refused = CloudExecResult(exitCode: 1, stdout: "", stderr: """
            {
              "error": {
                "code": "rpc",
                "message": "vmHost stays off here: it is only for a VM cmux created"
              }
            }
            """)
        #expect(CloudVmHost.parse(refused) == nil)
        #expect(CloudVmHost.failure(refused) == "vmHost stays off here: it is only for a VM cmux created")
        let old = CloudExecResult(exitCode: 2, stdout: "", stderr: "error: unrecognized subcommand 'vm-host'\n\nUsage: acpmux host <COMMAND>")
        #expect(CloudVmHost.parse(old) == nil)
        #expect(CloudVmHost.failure(old) == "error: unrecognized subcommand 'vm-host'", "an older cmux-tui says why")
    }

    @MainActor final class Machine {
        var on = true
        var commands: [String] = []
    }

    @Test func theStoreReadsOnceWhenConnectedAndSetsAnswerTheNewState() async throws {
        let machine = Machine()
        let store = CloudVmHostStore(exec: { _, command in
            await MainActor.run {
                machine.commands.append(command)
                if command.hasSuffix("vm-host off") { machine.on = false }
                if command.hasSuffix("vm-host on") { machine.on = true }
                return CloudExecResult(exitCode: 0, stdout: "{\"vmHost\": \(machine.on), \"cmuxVm\": true}", stderr: "")
            }
        })
        #expect(store.state("m1", readable: false) == nil)
        #expect(machine.commands.isEmpty, "a machine that is not connected is not asked (and not woken)")
        #expect(store.state("m1", readable: true) == nil)
        for _ in 0..<500 where store.entries["m1"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.state("m1", readable: true) == .known(CloudVmHost.State(on: true, cmuxVM: true)))
        #expect(machine.commands.count == 1, "read once")
        #expect(await store.set("m1", on: false) == nil)
        #expect(store.entries["m1"] == .known(CloudVmHost.State(on: false, cmuxVM: true)))
        #expect(await store.set("m1", on: true) == nil)
        #expect(store.entries["m1"] == .known(CloudVmHost.State(on: true, cmuxVM: true)))
        #expect(machine.commands.count == 3)
    }

    @Test func aRefusedSetKeepsTheLastStateAndSaysWhy() async throws {
        let store = CloudVmHostStore(exec: { _, _ in
            CloudExecResult(exitCode: 1, stdout: "", stderr: "{\"error\": {\"message\": \"vmHost stays off here\"}}")
        })
        #expect(await store.set("m1", on: true) == "vmHost stays off here")
        guard case .failed(let why, _, nil) = store.entries["m1"] else { Issue.record("\(String(describing: store.entries["m1"]))"); return }
        #expect(why == "vmHost stays off here")
    }

    @MainActor final class Recorder {
        var sets: [String] = []
    }

    private func page() async throws -> (SettingsPageProvider, Recorder, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-vm-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let recorder = Recorder()
        page.setMachineVmHost = { id, on in recorder.sets.append("\(id) \(on)"); return nil }
        return (page, recorder, directory)
    }

    @Test func pageScriptAloneNeverTurnsItOnAndOffNeedsNoClick() async throws {
        let (page, recorder, directory) = try await page()
        defer { try? FileManager.default.removeItem(at: directory) }
        let on: JSONValue = ["id": "vm_1", "on": true], off: JSONValue = ["id": "vm_1", "on": false]
        do {
            _ = try await page.call("cmux.settings.machines.vm_host", params: on, context: PageCallContext(page: PageDescriptor.settings.id))
            Issue.record("page script turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(recorder.sets.isEmpty)
        _ = try await page.call("cmux.settings.machines.vm_host", params: off, context: PageCallContext(page: PageDescriptor.settings.id))
        let click = PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 42)
        _ = try await page.call("cmux.settings.machines.vm_host", params: on, context: click)
        #expect(recorder.sets == ["vm_1 false", "vm_1 true"])
    }
}
