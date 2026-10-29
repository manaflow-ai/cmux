import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// `cmux cloud new-machine --repo OWNER/NAME[@REF]` (CloudMachineRepo): the spec is checked on the
/// Mac (forms from #21028's `cmux vm clone`), and the machine's repo step uses the GitHub access the
/// machine already has, resets every other helper and writes no token.
@Suite
struct CloudMachineRepoTests {
    @Test func theAcceptedFormsAllNameTheSameRepository() throws {
        for spec in ["manaflow-ai/cmux", "manaflow-ai/cmux.git", "https://github.com/manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux.git",
                     "https://www.github.com/manaflow-ai/cmux/", "http://github.com/manaflow-ai/cmux", "git@github.com:manaflow-ai/cmux.git",
                     "ssh://git@github.com/manaflow-ai/cmux.git", "  manaflow-ai/cmux\n"] {
            let repo = try CloudMachineRepo.parse(spec)
            #expect(repo == CloudMachineRepo(owner: "manaflow-ai", name: "cmux"), "\(spec)")
            #expect(repo.url == "https://github.com/manaflow-ai/cmux.git")
            #expect(repo.directory == "work/cmux")
        }
    }

    @Test func aRefComesFromAtOrFromTree() throws {
        #expect(try CloudMachineRepo.parse("manaflow-ai/cmux@feat-cmux-next").ref == "feat-cmux-next")
        #expect(try CloudMachineRepo.parse("git@github.com:manaflow-ai/cmux.git@v1.2.3").ref == "v1.2.3")
        #expect(try CloudMachineRepo.parse("https://github.com/manaflow-ai/cmux/tree/lane/pm-x").ref == "lane/pm-x")
        #expect(try CloudMachineRepo.parse("https://github.com/manaflow-ai/cmux/tree/lane/pm-x@main").ref == "main", "@REF wins")
        let sha = String(repeating: "a", count: 40)
        #expect(try CloudMachineRepo.parse("o/r@\(sha)").spec == "o/r@\(sha)")
    }

    @Test func credentialsInTheURLAreRefused() {
        for spec in ["https://ghp_secret@github.com/o/r", "https://x:ghp_secret@github.com/o/r", "ssh://ghp_secret@github.com/o/r.git",
                     "ssh://git:pw@github.com/o/r.git", "ghp_secret@github.com:o/r.git"] {
            #expect(throws: CloudMachineRepo.Invalid.credentialsInURL, "\(spec)") { try CloudMachineRepo.parse(spec) }
        }
    }

    @Test func anythingButAPlainGitHubRepositoryIsRefused() {
        for spec in ["", "cmux", "o/r/x", "https://gitlab.com/o/r", "https://github.com/o", "https://github.com:8443/o/r",
                     "https://github.com/o/r?x=1", "file:///tmp/r", "evilgithub.com:o/r", "o/-r", "o/.r", "o/r;rm -rf ~", "o/r b"] {
            #expect(throws: CloudMachineRepo.Invalid.unrecognized, "\(spec)") { try CloudMachineRepo.parse(spec) }
        }
    }

    @Test func aRefThatNeedsQuotingIsRefused() {
        for ref in ["HEAD", "HEAD/x", "topic/.hidden", "a.lock/b", "-x", "a..b", "a b", "a'b", "a\"b", "a;b", "x.lock", "a/", "$(id)", "a@{1}"] {
            #expect(throws: CloudMachineRepo.Invalid.invalidRef, "\(ref)") { try CloudMachineRepo.parse("o/r@\(ref)") }
        }
    }

    @Test func theAppSaysWhyWithoutEchoingTheSpec() {
        let invocation = ActionInvocation(arguments: ["repo": .string("https://ghp_secret@github.com/o/r")], origin: .cli)
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(invocation) }
        do { _ = try CloudHandlers.newMachineRequest(invocation) } catch {
            #expect(!String(describing: error).contains("ghp_secret"))
        }
        #expect(throws: ActionFailure.self, "a bare --repo is refused, never a plain machine") {
            try CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["repo": .bool(true)], origin: .cli))
        }
        let request = try? CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["repo": .string("o/r@main")], origin: .cli))
        #expect(request?.isDefault == false)
        #expect(request?.repo == CloudMachineRepo(owner: "o", name: "r", ref: "main"))
    }

    @Test func theStepResetsEveryOtherHelperAndWritesNoToken() throws {
        let step = CloudMachineRepo(owner: "o", name: "r", ref: "main").step
        let reset = try #require(step.range(of: "git -c credential.helper= -c core.askPass= ")), chosen = try #require(step.range(of: "-c \"credential.https://github.com.helper=$helper\""))
        #expect(chosen.lowerBound < reset.lowerBound, "g puts the chosen helper after the reset in git's argv, so the reset does not clear it")
        #expect(step.contains("export GIT_TERMINAL_PROMPT=0 GIT_TRACE_REDACT=1 GIT_TRACE=0 GIT_TRACE_CURL=0"), "no inherited request trace reaches the log")
        #expect(step.contains("GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0"), "nor a configured trace2 target")
        #expect(step.contains("--includes --get-all credential.https://github.com.helper"))
        #expect(step.contains("export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1"), "no configured username (a token) or helper after the lane helper is read")
        #expect(step.contains("-c credential.username= -c credential.https://github.com.username="))
        #expect(step.contains("unset GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT"))
        #expect(step.contains(#"lane="!$HOME/.local/bin/lane-gh-credential""#), "only the lane bootstrap's exact helper, never one that only names it")
        #expect(step.contains(#"grep -qxF -- "$lane""#))
        #expect(step.contains("[ -S /run/cmux-vm-agent/agent.sock ]"))
        #expect(step.contains("github credential"))
        for fetches in ["checkout", "merge", "status", "fetch", "clone"] {
            #expect(!step.contains("git -C \"$dir\" \(fetches)") && !step.contains("git \(fetches) "), "\(fetches) goes through g (a blobless clone fetches on demand)")
        }
        #expect(step.contains(#"checkout --quiet --detach "$commit" --"#), "a ref is resolved to a commit, never read as a path")
        // Only the code: the comments may say what it guards against.
        let code = step.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        for leak in ["token", "GH_TOKEN", "password", "credential.helper=store", "hosts.yml", "gh auth"] {
            #expect(!code.contains(leak), "\(leak)")
        }
        #expect(step.contains("url='https://github.com/o/r.git'; ref='main'; dir=\"$HOME/work/r\""))
        #expect(step.contains("exit \(CloudMachineRepo.needsGitHubExit)"))
    }

    @Test func theRecordNamesTheRepositoryAndNoSecret() throws {
        let object = try JSONSerialization.jsonObject(with: CloudMachineRepo(owner: "o", name: "r", ref: "v1").record) as? [String: String]
        #expect(object == ["url": "https://github.com/o/r.git", "owner": "o", "name": "r", "ref": "v1", "dir": "~/work/r"])
    }

    nonisolated final class FakeMachine: @unchecked Sendable {
        var writes: [String] = []
        var data: [Data] = []
        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(write: { path, data, _ in self.writes.append(path); self.data.append(data) },
                                          exec: { _ in CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "") })
        }
    }

    @Test func aRepoAloneStillRunsTheRunnerAndItsStepGoesBesideIt() async throws {
        let request = CloudMachineRequest(repo: CloudMachineRepo(owner: "o", name: "r"))
        let bootstrap = try #require(try await request.loadScript(work: BackgroundWork()))
        #expect(bootstrap.contents == CloudMachineBootstrap.noScript)
        let fake = FakeMachine()
        #expect(await bootstrap.start(name: nil, on: fake.machine, startID: "ab").status == "started")
        let staged = CloudMachineBootstrap.directory + "/in-ab"
        #expect(fake.writes == ["\(staged)/script", "\(staged)/env", "\(staged)/run", "\(staged)/repo.json", "\(staged)/repo"])
        #expect(fake.data.last == Data(CloudMachineRepo(owner: "o", name: "r").step.utf8))
        #expect(try await CloudMachineRequest().loadScript(work: BackgroundWork()) == nil)
    }

    @MainActor @Test func aRetryStartsABootstrapThatHasNotStartedOrFailed() {
        var request = CloudMachineRequest(repo: CloudMachineRepo(owner: "o", name: "r"))
        request.script = CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript, repo: request.repo)
        let creation = CloudMachineCreation(windowID: nil, request: request)
        #expect(CloudCreationFlow.needsBootstrap(creation), "not started yet")
        creation.noteBootstrap(CloudMachineBootstrap.Outcome(status: "failed", reason: "upload failed"))
        #expect(CloudCreationFlow.needsBootstrap(creation), "a failed start is tried again")
        creation.noteBootstrap(CloudMachineBootstrap.Outcome(status: "running"))
        #expect(!CloudCreationFlow.needsBootstrap(creation), "a start the machine took is not sent twice")
        #expect(!CloudCreationFlow.needsBootstrap(CloudMachineCreation(windowID: nil)), "no bootstrap asked")
        var configured = CloudMachineRequest()
        configured.machineConfig = CloudMachineConfig(contents: nil)
        let applying = CloudMachineCreation(windowID: nil, request: configured)
        #expect(CloudCreationFlow.needsBootstrap(applying) && !CloudCreationFlow.needsScript(applying), "a machine config alone still gets its apply")
        applying.noteMachineConfig(CloudMachineBootstrap.Outcome(status: "started"))
        #expect(!CloudCreationFlow.needsBootstrap(applying), "an apply the machine took is not sent twice")
    }

    @Test func theRunnerClonesFirstAndRetriesAfterAScriptThatSetsUpGitHub() throws {
        let runner = CloudMachineBootstrap.runner
        let step = try #require(runner.range(of: "repo_step\n")), script = try #require(runner.range(of: #""$d/script" >>"#))
        #expect(step.lowerBound < script.lowerBound)
        #expect(runner.contains(#"if [ "$code" -eq 0 ] && [ "$repo_code" -ne 0 ]; then repo_step; code=$?; step=repo; fi"#))
        #expect(runner.contains(#""repo":%s"#))
        #expect(runner.contains(#""script_sha256":"%s","start_sha256":"%s","repo":%s"#) && runner.contains(#"sum=$(sha256sum "$d/script" | cut -d' ' -f1)"#),
                "script_sha256 stays the script's own digest; the repo step only joins start_sha256")
        #expect(runner.contains(#"if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"""#), "the same script with another repo runs again")
        let start = CloudMachineBootstrap.startCommand(CloudMachineBootstrap.stagingDirectory("ab"))
        let held = try #require(start.range(of: "flock -n 6")), moved = try #require(start.range(of: #"as_u mv -f "$s/$f" "$d/$f""#))
        let released = try #require(start.range(of: "exec 6<&-"))
        #expect(held.lowerBound < moved.lowerBound && moved.lowerBound < released.lowerBound,
                "a start's files replace the bootstrap folder's only while it holds the runner's lock: never under a running runner")
        #expect(start.contains(#"flock -n 6 || { as_u rm -rf "$s" || true; echo running; exit 0; }"#), "a start while a runner runs drops its own files")
        let fresh = try #require(start.range(of: #"-lt 60 ]; then as_u rm -rf "$s" || true; echo running"#))
        #expect(held.lowerBound < fresh.lowerBound && fresh.lowerBound < moved.lowerBound,
                "an earlier start's runner that has not taken over yet keeps its files")
        let alive = try #require(runner.range(of: "flock 8\n")), late = try #require(runner.range(of: "-ge 60 ]; then"))
        let running = try #require(runner.range(of: "status running null"))
        #expect(alive.upperBound < late.lowerBound && late.lowerBound < running.lowerBound && runner.contains(#"status failed 75 ',"late":true'; exit 75"#),
                "a runner a minute late (an apply may have stopped waiting) does not run, checked while it holds `alive`")
        #expect(!runner.contains("start.lock"), "the runner never waits on start.lock, which an apply holds while it waits for the runner")
    }
}
