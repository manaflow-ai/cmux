import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Code Puppy managed plugin")
struct CodePuppyPluginTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func registryRoundTripPreservesUnrelatedValues() throws {
        let original = Data(#"{"theme":"dark","plugins":[{"name":"other","path":"/other","enabled":false}]}"#.utf8)
        let installed = try CodePuppyPlugin.installing(registryData: original, pluginPath: "/managed")
        let json = try object(installed)
        #expect(json["theme"] as? String == "dark")
        let plugins = try #require(json["plugins"] as? [[String: Any]])
        #expect(plugins.count == 2)
        #expect(plugins.first?["enabled"] as? Bool == false)
        #expect(plugins.last?["name"] as? String == "cmux-session")
        #expect(plugins.last?["path"] as? String == "/managed")
        #expect(plugins.last?["cmux_managed"] as? Bool == true)
        #expect(try CodePuppyPlugin.installing(registryData: installed, pluginPath: "/managed") == installed)
        let removed = try #require(try CodePuppyPlugin.uninstalling(registryData: installed, pluginPath: "/managed"))
        #expect(NSDictionary(dictionary: try object(removed)) == NSDictionary(dictionary: try object(original)))
        #expect(try CodePuppyPlugin.uninstalling(registryData: nil, pluginPath: "/managed") == nil)
    }

    @Test func registryRejectsMalformedAndUnownedCollisions() {
        for text in ["[]", "null", "{", #"{"plugins":{}}"#, #"{"plugins":[3]}"#,
                     #"{"plugins":[{"name":"cmux-session","path":"/managed"}]}"#,
                     #"{"plugins":[{"name":"other","path":"/managed"}]}"#,
                     #"{"plugins":[{"name":"cmux-session","path":"/elsewhere","cmux_managed":true}]}"#] {
            #expect(throws: (any Error).self) {
                try CodePuppyPlugin.installing(registryData: Data(text.utf8), pluginPath: "/managed")
            }
            #expect(throws: (any Error).self) {
                try CodePuppyPlugin.uninstalling(registryData: Data(text.utf8), pluginPath: "/managed")
            }
        }
    }

    @Test func renderedCallbacksUseAutosaveIdentityAndPreserveOutcomes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("plugin.py")
        let cli = "/fake/quote'\"\\cli"
        try CodePuppyPlugin.render(cmuxExecutablePath: cli, socketPath: "/tagged socket").write(to: plugin, atomically: true, encoding: .utf8)
        let script = #"""
import asyncio, importlib.util, json, os, sys, types
registered = {}
package = types.ModuleType('code_puppy')
config = types.ModuleType('code_puppy.config')
config.get_current_autosave_session_name = lambda: 'auto_session_actual'
callbacks = types.ModuleType('code_puppy.callbacks')
callbacks.register_callback = lambda name, fn: registered.update({name: fn})
package.config = config
sys.modules.update({'code_puppy': package, 'code_puppy.config': config, 'code_puppy.callbacks': callbacks})
spec = importlib.util.spec_from_file_location('plugin', sys.argv[1]); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
assert set(registered) == {'agent_run_start','agent_run_end','pre_tool_call','post_tool_call','post_autosave','shutdown'}
calls = []
def run(argv, **kw):
    calls.append((argv, json.loads(kw['input']), kw['env']))
module.subprocess.run = run
async def exercise():
    await registered['agent_run_start']('code-puppy', 'model', 'uuid-root')
    await registered['agent_run_start']('retriever', 'model', 'uuid-child')
    await registered['agent_run_end']('retriever', 'model', 'uuid-child')
    await registered['pre_tool_call']('read_file', {'file_path':'/tmp/file'}, None)
    await registered['post_tool_call']('read_file', {}, 'ok', 2.5, None)
    await registered['agent_run_end']('code-puppy','model','uuid-root',False,RuntimeError('oops'),None,{})
    await registered['post_autosave'](types.SimpleNamespace(session_name='auto_session_actual'))
    await registered['shutdown']()
asyncio.run(exercise())
assert [argv[-1] for argv,payload,env in calls] == ['session-start','prompt-submit','pre-tool-use','post-tool-use','stop','session-update','session-end']
assert all(payload['session_id'] == 'auto_session_actual' for _,payload,_ in calls)
assert all(env['CMUX_CODE_PUPPY_PID'] == 'parent-pid' for _,_,env in calls)
assert calls[4][1]['success'] is False and calls[4][1]['error'] == 'oops'
assert calls[4][1]['type'] == 'error'
assert calls[5][1]['success'] is False
assert calls[0][0][0] == sys.argv[2] and calls[0][0][1:3] == ['--socket','/tagged socket']
os.environ['CMUX_CODE_PUPPY_HOOKS_DISABLED'] = '1'
asyncio.run(exercise()); assert len(calls) == 7
os.environ.pop('CMUX_CODE_PUPPY_HOOKS_DISABLED'); os.environ.pop('CMUX_SURFACE_ID')
asyncio.run(exercise()); assert len(calls) == 7
os.environ['CMUX_SURFACE_ID'] = 'surface'; os.environ['CMUX_AGENT_MANAGED_SUBAGENT'] = '1'
asyncio.run(exercise()); assert len(calls) == 7
os.environ.pop('CMUX_AGENT_MANAGED_SUBAGENT')
os.environ['CMUX_BUNDLED_CLI_PATH'] = '/ambient'; os.environ['CMUX_SOCKET_PATH'] = '/ambient.sock'
asyncio.run(exercise()); assert len(calls) == 14
assert calls[7][0][:3] == ['/ambient','--socket','/ambient.sock']
def unavailable(*args, **kwargs): raise OSError('not installed')
module.subprocess.run = unavailable
asyncio.run(exercise())
assert os.environ['CMUX_CODE_PUPPY_PID'] == 'parent-pid'
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, plugin.path, cli]
        var env = ProcessInfo.processInfo.environment
        env["CMUX_SURFACE_ID"] = "surface"
        env["CMUX_CODE_PUPPY_PID"] = "parent-pid"
        env.removeValue(forKey: "CMUX_BUNDLED_CLI_PATH")
        env.removeValue(forKey: "CMUX_SOCKET_PATH")
        env.removeValue(forKey: "CMUX_CODE_PUPPY_HOOKS_DISABLED")
        env.removeValue(forKey: "CMUX_AGENT_MANAGED_SUBAGENT")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: errors))
    }
}
