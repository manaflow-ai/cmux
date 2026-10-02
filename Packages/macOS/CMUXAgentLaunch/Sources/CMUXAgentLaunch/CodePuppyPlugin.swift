import Foundation

/// cmux-owned Code Puppy callback plugin and ownership registry transformations.
public enum CodePuppyPlugin {
    public static let pluginName = "cmux-session"
    public static let registryFileName = "external_plugins.json"

    /// Render a dependency-free Python callback module (not a shell script).
    public static func render(cmuxExecutablePath: String, socketPath: String?) -> String {
        let settings: [String: Any] = [
            "executable": cmuxExecutablePath,
            "socket": socketPath as Any? ?? NSNull(),
        ]
        // Double JSON encoding gives a Python string literal containing JSON;
        // quotes, backslashes, control characters and non-ASCII paths stay data.
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let literal = String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        return pythonSource.replacingOccurrences(of: "__CMUX_SETTINGS__", with: literal)
    }

    /// Add an owned entry without adopting a pre-existing user plugin.
    public static func installing(registryData: Data?, pluginPath: String) throws -> Data {
        var (object, plugins, ownedIndex) = try validatedRegistry(registryData, pluginPath: pluginPath)
        if ownedIndex == nil {
            plugins.append(["name": pluginName, "path": pluginPath, "cmux_managed": true])
        }
        object["plugins"] = plugins
        return try encoded(object)
    }

    /// Remove only the entry matching both our ownership marker and path.
    public static func uninstalling(registryData: Data?, pluginPath: String) throws -> Data? {
        var (object, plugins, ownedIndex) = try validatedRegistry(registryData, pluginPath: pluginPath)
        guard let registryData else { return nil }
        guard let ownedIndex else { return registryData }
        plugins.remove(at: ownedIndex)
        object["plugins"] = plugins
        return try encoded(object)
    }

    public enum RegistryError: Error, Equatable {
        case invalidPath, malformedRegistry, collision
    }

    private static func validatedRegistry(_ data: Data?, pluginPath: String) throws -> ([String: Any], [[String: Any]], Int?) {
        guard pluginPath.hasPrefix("/"), !pluginPath.contains("\0") else { throw RegistryError.invalidPath }
        var object: [String: Any] = [:]
        if let data {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = parsed as? [String: Any] else { throw RegistryError.malformedRegistry }
            object = dictionary
        }
        let plugins: [[String: Any]]
        if let value = object["plugins"] {
            guard let entries = value as? [[String: Any]] else { throw RegistryError.malformedRegistry }
            plugins = entries
        } else {
            plugins = []
        }
        var ownedIndex: Int?
        for (index, entry) in plugins.enumerated() {
            guard let name = entry["name"] as? String, !name.isEmpty,
                  let path = entry["path"] as? String, !path.isEmpty else { throw RegistryError.malformedRegistry }
            guard name == pluginName || path == pluginPath else { continue }
            // JSON booleans alone prove this metadata marker; 1/string truthiness do not.
            let marker = entry["cmux_managed"] as? NSNumber
            guard name == pluginName, path == pluginPath,
                  marker?.stringValue == "1", marker?.objCType.pointee == 99,
                  ownedIndex == nil else { throw RegistryError.collision }
            ownedIndex = index
        }
        return (object, plugins, ownedIndex)
    }

    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    private static let pythonSource = #"""
    # cmux-managed Code Puppy plugin v1. Installed by cmux; no model context output.
    import asyncio
    import json
    import os
    import subprocess
    from code_puppy import config
    from code_puppy.callbacks import register_callback

    _settings = json.loads(__CMUX_SETTINGS__)
    _runs = []
    _session = None


    def _enabled():
        return bool(os.environ.get("CMUX_SURFACE_ID")) and os.environ.get("CMUX_CODE_PUPPY_HOOKS_DISABLED") != "1" and os.environ.get("CMUX_AGENT_MANAGED_SUBAGENT") != "1"


    def _send_sync(command, payload):
        if not _enabled():
            return
        # Use the launching terminal's tagged target when available, otherwise
        # the install's pinned target. Never change the process-wide environment
        # or replace an inherited parent PID with our own process identity.
        executable = os.environ.get("CMUX_BUNDLED_CLI_PATH") or _settings["executable"]
        socket = os.environ.get("CMUX_SOCKET_PATH") or _settings["socket"]
        argv = [executable]
        if socket:
            argv += ["--socket", socket]
        env = dict(os.environ)
        env.setdefault("CMUX_CODE_PUPPY_PID", str(os.getpid()))
        try:
            subprocess.run(argv + command, input=json.dumps(payload), text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=5, check=False, env=env)
        except (OSError, subprocess.SubprocessError):
            pass


    async def _send(subcommand, event, **fields):
        if not _enabled() or not _session:
            return
        payload = dict(session_id=_session, hook_event_name=event, cwd=os.getcwd(), **fields)
        await asyncio.to_thread(_send_sync, ["hooks", "code-puppy", subcommand], payload)


    async def _on_start(agent_name, model_name, session_id=None):
        global _session
        if not _enabled():
            return
        # Run UUIDs are used only to pair nested callbacks, NEVER as resume IDs.
        nested = bool(_runs)
        _runs.append(session_id)
        if nested:
            return
        try:
            _session = config.get_current_autosave_session_name()
        except Exception:
            _session = None
            return
        await _send("session-start", "SessionStart", agent_name=agent_name)
        await _send("prompt-submit", "UserPromptSubmit", agent_name=agent_name)


    async def _on_end(agent_name, model_name, session_id=None, success=True,
                      error=None, response_text=None, metadata=None):
        if not _runs or session_id not in _runs:
            return
        index = _runs.index(session_id)
        _runs.pop(index)
        if index != 0:
            return
        # Nested runs that outlive their parent must not retain root ownership.
        _runs.clear()
        message = str(error) if error is not None else ("Agent run failed" if not success else None)
        await _send("stop", "Stop", agent_name=agent_name, success=bool(success),
                    error=message, message=message, type="error" if not success else "stop",
                    response_text=response_text)


    async def _on_pre(tool_name, tool_args, context=None):
        if len(_runs) != 1:
            return
        fields = dict(tool_name=tool_name, tool_input=tool_args)
        await _send("pre-tool-use", "PreToolUse", **fields)


    async def _on_post(tool_name, tool_args, result, duration_ms, context=None):
        if len(_runs) != 1:
            return
        fields = dict(tool_name=tool_name, tool_input=tool_args, tool_duration_ms=duration_ms)
        await _send("post-tool-use", "PostToolUse", **fields)


    async def _on_shutdown():
        global _session
        await _send("session-end", "SessionEnd")
        _session = None
        _runs.clear()


    register_callback("agent_run_start", _on_start)
    register_callback("agent_run_end", _on_end)
    register_callback("pre_tool_call", _on_pre)
    register_callback("post_tool_call", _on_post)
    register_callback("shutdown", _on_shutdown)
    """#
}
