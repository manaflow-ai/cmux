import CmuxNextCloud
import Foundation
import Testing

/// `.cmux/machine.toml` (CloudMachineConfig): the applier the machine runs, and the bootstrap start's
/// half of their handshake (`start.lock`).
@Suite
struct CloudMachineConfigTests {
    @Test func theApplierKeepsItsFilesPrivateAndNeverRoutesTheModelPlane() {
        for name in ["OPENAI_BASE_URL", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "OPTIND", "PS1", "ZDOTDIR"] {
            #expect(CloudMachineConfig.applier.contains("\"\(name)\""), "a file from a repo never routes the model plane: \(name)")
        }
        #expect(CloudMachineConfig.applier.contains("def write(path, text, mode=0o600)"))
        #expect(CloudMachineConfig.applier.hasPrefix("#!/usr/bin/env python3\n"))
        #expect(!CloudMachineConfig.applier.contains("log_tail"), "no setup output in status.json, which the app reads over the file API")
        #expect(CloudMachineConfig.applier.contains(#"='((?:[^']|'\\'')*)'"#) && !CloudMachineConfig.applier.contains("len(value) >="),
                "every delivered value is masked in setup's log, however short, multi-line ones too")
    }

    @Test func aBootstrapStartWaitsForARunningApplyAndNeverRerunsADoneScript() throws {
        let start = CloudMachineBootstrap.startCommand
        let lock = try #require(start.range(of: "flock -w 15 7"))
        let runner = try #require(start.range(of: "flock -n 6"))
        let done = try #require(start.range(of: #""\"state\":\"done\".*"#))
        let starting = try #require(start.range(of: #"{"state":"starting""#))
        let release = try #require(start.range(of: "exec 6<&-"))
        let launch = try #require(start.range(of: "systemd-run"))
        #expect(lock.lowerBound < runner.lowerBound && runner.lowerBound < done.lowerBound && done.lowerBound < starting.lowerBound
                    && starting.lowerBound < release.lowerBound && release.lowerBound < launch.lowerBound,
                "under start.lock and the runner's lock: a running runner, then a done script, then `starting`; the lock goes before the launch")
        #expect(CloudMachineBootstrap.runner.contains(#"if grep -q "\"state\":\"done\".*"#),
                "a runner an earlier start launched late finds the script done and does not run it again")
        #expect(start.contains("7<&-"), "the setsid runner never inherits start.lock")
        #expect(CloudMachineBootstrap.runner.contains(#"exec 8>"$d/alive""#), "the runner holds `alive` for its whole life")
        #expect(CloudMachineBootstrap.runner.contains(#"[ -f "$d/alive" ] && [ ! -L "$d/alive" ] || rm -f "$d/alive""#),
                "a link or FIFO at `alive` is replaced by a regular file before it is locked")
        #expect(start.contains(#"[ -f "$d/start.lock" ] && [ ! -L "$d/start.lock" ]"#), "a FIFO start.lock is refused, never opened")
    }
}
