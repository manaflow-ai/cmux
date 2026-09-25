import Foundation

/// `cmux vm dev`: one command from a local folder to a running dev layout on a
/// cloud machine — the composition an agent otherwise types by hand as
/// `vm push` → `vm tree --refresh` → `vm layout apply` →
/// `vm workspace open` → `vm open <port>`.
///
/// Every step goes through the SAME socket methods and command builders those
/// verbs use (`vm.status`, `runVMPushCommand`, `vm.tree {refresh}`,
/// `vmLayoutApplyCommand` over `vm.exec`, `vm.workspace_open`,
/// `vm.open_port`), so a script that runs the verbs one by one and `vm dev` cannot
/// disagree about what a workspace, a layout, or an open is. Nothing here shells out.
///
/// Idempotent by construction: the workspace is get-or-create by name; a second run
/// against a workspace that already has panes keeps its layout and just reopens it.
extension CMUXCLI {
    static var vmDevUsage: String {
        """
        Usage: cmux vm dev <machine> [<local-dir>] [--name <workspace>] [--layout <file>] [--command "<dev command>"] [--port <n>] [--remote <path>] [--sync|--no-sync] [--no-open] [--dry-run] [--json]

        From a folder to a running dev layout on a cloud machine, in one command:
          1. route     confirm the machine (`vm.status`) and bind this folder to it, so
                       `cmux vm run --sync` / `cmux vm agent --sync` from here land on the same machine
          2. sync      push the folder to <remote> (default work/<basename>; the `vm push` defaults
                       skip .git, node_modules, .venv, __pycache__, .DS_Store)
          3. detect    pick the dev command and port from the project (or take --command / --port)
          4. workspace get-or-create the machine workspace <name> (default: the folder's basename)
                       and build the layout in it: a `dev` pane running the command on the left,
                       a `shell` pane (focused) on the right with a browser tab on the port
          5. open      open that workspace here with the same geometry (unless --no-open) and mint
                       the port's public URL (`cmux vm open <machine> <port>`)

        Detection, first match wins (the command is typed into a login shell in <remote>):
          package.json     <pm> install && <pm> run dev   (pm: bun, pnpm, yarn, or npm by lockfile;
                           `start` when there is no `dev` script; port from -p/--port/PORT= in the
                           script, else the framework default: next/nuxt/react-scripts 3000,
                           vite/svelte-kit/remix 5173, astro 4321, ng 4200, expo 8081, wrangler 8787)
          Cargo.toml       cargo run                       go.mod         go run .
          Makefile (dev:)  make dev                        manage.py      python manage.py runserver 0.0.0.0:8000  (8000)
          uv.lock          uv sync                         pyproject.toml pip install -e .
          requirements.txt pip install -r requirements.txt index.html     python3 -m http.server 8000  (8000)
          nothing          shell pane only (pass --command to run something anyway)

        Options:
          <local-dir>          The project folder (default: the current directory).
          --name <workspace>   Machine workspace to create or reuse (default: the folder's basename).
          --layout <file>      Use this layout document instead of the built-in dev layout (same format
                               as `cmux vm layout apply`; validated here first, exit 2 when invalid).
          --command "<cmd>"    Run this instead of the detected dev command.
          --port <n>           The port the dev server listens on (browser tab + public URL).
          --remote <path>      Where the folder lives on the machine (default work/<basename>).
          --sync | --no-sync   Push the folder first. Default: on when a folder is named or a project
                               was detected; off for a folder with nothing recognizable in it.
          --no-open            Build on the machine only; print the open command instead.
          --dry-run            Print the plan (detection, remote path, layout) without touching anything.
          --json               {machine, workspace_id, local_workspace_id, workspace_name, existing, local,
                                remote, synced, command, port, url, terminals: {dev, shell}, layout_applied, opened}

        Examples:
          cmux vm dev brave-otter                      # this folder → brave-otter, layout opened here
          cmux vm dev brave-otter ./web --name web     # a subfolder, workspace named web
          cmux vm dev brave-otter --command "bun run dev --host" --port 5173
          cmux vm dev brave-otter --dry-run --json     # what would happen, no socket traffic
        Afterwards: `cmux vm terminal output <machine> <dev-terminal>` reads the server log;
        `cmux vm terminal send <machine> <shell-terminal> 'bun test' --keys enter` runs a command.
        """
    }

    // MARK: - Project detection (pure; no socket, no machine)

    /// What `vm dev` decided about a folder: the family it recognized, the command it will
    /// type into the `dev` pane, the port the browser tab and public URL point at, and
    /// one human sentence saying why.
    struct VMDevDetection: Equatable {
        let kind: String
        let command: String?
        let port: Int?
        let detail: String

        static let unrecognized = VMDevDetection(kind: "none", command: nil, port: nil, detail: "no package.json, Cargo.toml, go.mod, Makefile dev target, manage.py, pyproject.toml, requirements.txt, or index.html here")
    }

    /// Framework → default dev port, decided from the script's words (what the author
    /// actually runs: `next dev`, `bunx vite --host`, `ng serve`) and, when the script
    /// names no framework, from the dependencies. Whole tokens only, so `expose-gc`
    /// never reads as expo and `running` never as ng.
    static let vmDevScriptTokenPorts: [(token: String, port: Int)] = [
        ("next", 3000),
        ("nuxt", 3000),
        ("nuxi", 3000),
        ("react-scripts", 3000),
        ("vite", 5173),
        ("react-router", 5173),
        ("remix", 5173),
        ("astro", 4321),
        ("ng", 4200),
        ("expo", 8081),
        ("wrangler", 8787),
    ]

    static let vmDevDependencyPorts: [(package: String, port: Int)] = [
        ("next", 3000),
        ("nuxt", 3000),
        ("react-scripts", 3000),
        ("@sveltejs/kit", 5173),
        ("@remix-run/dev", 5173),
        ("react-router", 5173),
        ("vite", 5173),
        ("astro", 4321),
        ("@angular/cli", 4200),
        ("expo", 8081),
        ("wrangler", 8787),
    ]

    static func detectVMDevProject(in directory: URL) -> VMDevDetection {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(name).path) }

        if exists("package.json") {
            return detectVMDevNodeProject(in: directory)
        }
        if exists("Cargo.toml") {
            return VMDevDetection(kind: "cargo", command: "cargo run", port: nil, detail: "Cargo.toml → cargo run")
        }
        if exists("go.mod") {
            return VMDevDetection(kind: "go", command: "go run .", port: nil, detail: "go.mod → go run .")
        }
        if exists("Makefile"),
           let makefile = try? String(contentsOf: directory.appendingPathComponent("Makefile"), encoding: .utf8),
           vmDevMakefileHasDevTarget(makefile) {
            return VMDevDetection(kind: "make", command: "make dev", port: nil, detail: "Makefile has a dev target → make dev")
        }
        if exists("manage.py") {
            // 0.0.0.0, not the runserver default of 127.0.0.1: the machine's port proxy
            // reaches the process from outside the loopback interface.
            return VMDevDetection(kind: "django", command: "python manage.py runserver 0.0.0.0:8000", port: 8000, detail: "manage.py → Django runserver on 8000")
        }
        if exists("uv.lock") {
            return VMDevDetection(kind: "uv", command: "uv sync", port: nil, detail: "uv.lock → uv sync prepares the environment; start the app from the shell pane with `uv run <command>`")
        }
        if exists("pyproject.toml") {
            return VMDevDetection(kind: "python", command: "pip install -e .", port: nil, detail: "pyproject.toml → pip install -e . prepares the environment; start the app from the shell pane")
        }
        if exists("requirements.txt") {
            return VMDevDetection(kind: "python", command: "pip install -r requirements.txt", port: nil, detail: "requirements.txt → pip install -r requirements.txt; start the app from the shell pane")
        }
        if exists("index.html") {
            return VMDevDetection(kind: "static", command: "python3 -m http.server 8000", port: 8000, detail: "index.html and no package.json → a static server on 8000")
        }
        return .unrecognized
    }

    private static func detectVMDevNodeProject(in directory: URL) -> VMDevDetection {
        let manifestURL = directory.appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return VMDevDetection(kind: "node", command: nil, port: nil, detail: "package.json is not valid JSON; pass --command")
        }
        let scripts = (manifest["scripts"] as? [String: Any]) ?? [:]
        let packageManager = vmDevPackageManager(in: directory, manifest: manifest)
        let scriptName: String
        if let dev = scripts["dev"] as? String, !dev.isEmpty {
            scriptName = "dev"
        } else if let start = scripts["start"] as? String, !start.isEmpty {
            scriptName = "start"
        } else {
            return VMDevDetection(kind: "node", command: nil, port: nil, detail: "package.json has no dev or start script; pass --command")
        }
        let scriptText = (scripts[scriptName] as? String) ?? ""
        var dependencies = Set<String>()
        for key in ["dependencies", "devDependencies"] {
            for name in ((manifest[key] as? [String: Any]) ?? [:]).keys { dependencies.insert(name) }
        }
        let port = vmDevPort(inScript: scriptText) ?? vmDevFrameworkPort(script: scriptText, dependencies: dependencies)
        // Install first: node_modules never travels with `vm push`, and a cached install
        // is a no-op, so the pane works on the first run and stays fast on the next.
        let command = "\(packageManager) install && \(packageManager) run \(scriptName)"
        let portNote = port.map { " (port \($0))" } ?? " (no port recognized; pass --port to get a browser tab)"
        return VMDevDetection(
            kind: "node",
            command: command,
            port: port,
            detail: "package.json scripts.\(scriptName) = \"\(scriptText)\" with \(packageManager)\(portNote)"
        )
    }

    /// The lockfile decides, then `packageManager` in package.json, then npm.
    static func vmDevPackageManager(in directory: URL, manifest: [String: Any] = [:]) -> String {
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        if exists("bun.lock") || exists("bun.lockb") { return "bun" }
        if exists("pnpm-lock.yaml") { return "pnpm" }
        if exists("yarn.lock") { return "yarn" }
        if exists("package-lock.json") { return "npm" }
        if let declared = manifest["packageManager"] as? String {
            let name = declared.split(separator: "@").first.map(String.init) ?? ""
            if ["bun", "pnpm", "yarn", "npm"].contains(name) { return name }
        }
        return "npm"
    }

    /// `-p 4000`, `--port 4000`, `--port=4000`, `PORT=4000` anywhere in a script line.
    static func vmDevPort(inScript script: String) -> Int? {
        let patterns = [
            "(?:^|\\s)(?:-p|--port)[ =](\\d{2,5})(?:\\s|$)",
            "(?:^|\\s)PORT=(\\d{2,5})(?:\\s|$)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(script.startIndex..<script.endIndex, in: script)
            guard let match = regex.firstMatch(in: script, range: range),
                  match.numberOfRanges > 1,
                  let portRange = Range(match.range(at: 1), in: script),
                  let port = Int(script[portRange]), (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }

    static func vmDevFrameworkPort(script: String, dependencies: Set<String>) -> Int? {
        let tokens = Set(script.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "&" || $0 == ";" || $0 == "|" }).map(String.init))
        for entry in vmDevScriptTokenPorts where tokens.contains(entry.token) {
            return entry.port
        }
        for entry in vmDevDependencyPorts where dependencies.contains(entry.package) {
            return entry.port
        }
        return nil
    }

    /// A `dev:` rule at the start of a line (`dev: build`, `dev:: …`, `.PHONY` lines do not count).
    static func vmDevMakefileHasDevTarget(_ makefile: String) -> Bool {
        makefile.range(of: "(?m)^dev\\s*::?(?:\\s|$)", options: .regularExpression) != nil
    }

    // MARK: - The built-in layout (data; the same document `vm layout apply` takes)

    /// Left: the `dev` pane running the command. Right (focused): a `shell` pane, with a
    /// browser tab on the port when one is known. Without a command there is no dev
    /// pane — a single shell pane (plus the browser tab when --port was given).
    static func vmDevLayoutDocument(name: String, remote: String, command: String?, port: Int?) -> [String: Any] {
        var shellSurfaces: [[String: Any]] = [
            ["type": "terminal", "name": "shell", "cwd": remote, "focus": true],
        ]
        if let port {
            shellSurfaces.append(["type": "browser", "name": "preview", "url": "http://localhost:\(port)"])
        }
        let shellPane: [String: Any] = ["pane": ["surfaces": shellSurfaces]]
        let node: [String: Any]
        if let command {
            let devPane: [String: Any] = [
                "pane": ["surfaces": [["type": "terminal", "name": "dev", "command": command, "cwd": remote, "focus": false]]],
            ]
            node = ["direction": "horizontal", "split": 0.62, "children": [devPane, shellPane]]
        } else {
            node = shellPane
        }
        return ["name": name, "cwd": remote, "layout": node]
    }

    /// Terminal ids by surface name from the shim's apply summary
    /// (`{panes: [{pane_id, surfaces: [{type, name, terminal_id, …}]}]}`).
    static func vmDevTerminalIDs(fromApplyPayload payload: [String: Any]?) -> [String: String] {
        var ids: [String: String] = [:]
        for pane in (payload?["panes"] as? [[String: Any]]) ?? [] {
            for surface in (pane["surfaces"] as? [[String: Any]]) ?? [] {
                guard (surface["type"] as? String) == "terminal",
                      let name = surface["name"] as? String, !name.isEmpty,
                      let terminal = surface["terminal_id"] as? String, !terminal.isEmpty,
                      ids[name] == nil else { continue }
                ids[name] = terminal
            }
        }
        return ids
    }

    static func vmDevTerminalIDs(
        fromCatalogResources resources: [[String: Any]],
        machine: String,
        workspaceID: String
    ) -> [String: String] {
        var ids: [String: String] = [:]
        for resource in resources where (resource["kind"] as? String) == "terminal" {
            guard (resource["lifecycle"] as? String) != "exited",
                  Self.vmDevResourceBelongsToMachine(resource, machine: machine),
                  let terminalID = VMRemoteWorkspaceResolver().vmTerminalID(in: resource, machine: machine),
                  !terminalID.isEmpty else { continue }
            let view: [String: Any]
            switch VMRemoteWorkspaceResolver().resolveVMRemoteView(in: resource, workspaceID: workspaceID) {
            case .resolved(let resolved):
                view = resolved
            case .legacy:
                view = [:]
            case .notFound, .ambiguous, .unavailable:
                continue
            }
            let viewName = (view["name"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            let resourceName = (resource["title"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            guard let name = viewName ?? resourceName else { continue }
            if ids[name] == nil { ids[name] = terminalID }
        }
        return ids
    }

    /// Counts live and exited placements. An unknown catalog cannot prove the
    /// workspace is empty, or justify reporting that it already has panes.
    static func vmDevWorkspaceHasPlacedTerminals(
        _ resources: [[String: Any]],
        machine: String,
        workspaceID: String
    ) throws -> Bool {
        let resolver = VMRemoteWorkspaceResolver()
        var unavailableSelector: String?
        for resource in resources {
            guard Self.vmDevResourceBelongsToMachine(resource, machine: machine) else { continue }
            switch resolver.resolveVMRemoteView(in: resource, workspaceID: workspaceID) {
            case .resolved, .legacy:
                return true
            case .ambiguous:
                // Ambiguity is between views that match this workspace, so it
                // prevents choosing a tab but still proves the workspace has panes.
                return true
            case .unavailable:
                break
            case .notFound:
                continue
            }
            let selector = (resource["key"] as? String) ?? (resource["id"] as? String) ?? "?"
            unavailableSelector = unavailableSelector.map { min($0, selector) } ?? selector
        }
        if let selector = unavailableSelector {
            throw CLIError(message: "vm dev: terminal placement for workspace \(workspaceID) on \(machine) is unavailable (resource \(selector)); reconnect and retry")
        }
        return false
    }

    private static func vmDevResourceBelongsToMachine(_ resource: [String: Any], machine: String) -> Bool {
        if let resourceMachine = resource["machine"] as? String {
            return resourceMachine == machine
        }
        guard let id = resource["id"] as? String else { return false }
        return id.hasPrefix("\(machine)/")
    }

    // MARK: - The command

    private struct VMDevOptions {
        var machine = ""
        var localDirArgument: String?
        var name: String?
        var layoutFile: String?
        var command: String?
        var port: Int?
        var remote: String?
        var sync: Bool?
        var noOpen = false
        var dryRun = false
    }

    private static func parseVMDevOptions(_ rest: [String]) throws -> VMDevOptions {
        var options = VMDevOptions()
        var positional: [String] = []
        var index = 0
        func value(for flag: String, inline: String?) throws -> String {
            if let inline {
                guard !inline.isEmpty else { throw CLIError(message: "vm dev: \(flag) requires a value\n\n\(vmDevUsage)") }
                return inline
            }
            guard index + 1 < rest.count else { throw CLIError(message: "vm dev: \(flag) requires a value\n\n\(vmDevUsage)") }
            index += 1
            return rest[index]
        }
        while index < rest.count {
            let arg = rest[index]
            var flag = arg
            var inline: String?
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                flag = String(arg[..<equals])
                inline = String(arg[arg.index(after: equals)...])
            }
            switch flag {
            case "--name": options.name = try value(for: flag, inline: inline)
            case "--layout": options.layoutFile = try value(for: flag, inline: inline)
            case "--command": options.command = try value(for: flag, inline: inline)
            case "--remote": options.remote = try value(for: flag, inline: inline)
            case "--port":
                let raw = try value(for: flag, inline: inline)
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw CLIError(message: "vm dev: --port must be a port number between 1 and 65535 (got '\(raw)')\n\n\(vmDevUsage)")
                }
                options.port = port
            case "--sync": options.sync = true
            case "--no-sync": options.sync = false
            case "--no-open": options.noOpen = true
            case "--dry-run": options.dryRun = true
            case "--json": break
            default:
                guard !arg.hasPrefix("-") else {
                    throw CLIError(message: "vm dev: unknown flag '\(arg)'\n\n\(vmDevUsage)")
                }
                positional.append(arg)
            }
            index += 1
        }
        guard let machine = positional.first, !machine.isEmpty, positional.count <= 2 else {
            throw CLIError(message: vmDevUsage)
        }
        options.machine = machine
        options.localDirArgument = positional.count == 2 ? positional[1] : nil
        if let name = options.name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "vm dev: --name needs a workspace name\n\n\(vmDevUsage)")
        }
        return options
    }

    /// `vm.exec` budget for building the layout: the same as `vm layout apply` (the shim
    /// spawns a handful of shells and waits for their prompts).
    static let vmDevApplyExecTimeoutMs = CMUXCLI.vmLayoutApplyExecTimeoutMs

    func runVMDevCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmDevUsage)
            return
        }
        let options = try Self.parseVMDevOptions(rest)
        let machine = options.machine

        // The folder, resolved and checked before anything else: a typo must not push
        // the wrong tree or stage an empty workspace.
        let localPath = options.localDirArgument.map(resolvePath) ?? FileManager.default.currentDirectoryPath
        let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(message: "vm dev: no such folder: \(localURL.path)")
        }
        let basename = localURL.lastPathComponent
        guard !basename.isEmpty, basename != "/" else {
            throw CLIError(message: "vm dev: name the project folder (the filesystem root has no basename to use for the workspace and remote path)")
        }
        let workspaceName = options.name ?? basename
        let remote = options.remote ?? "work/\(basename)"

        let detection = Self.detectVMDevProject(in: localURL)
        let command = options.command ?? detection.command
        let port: Int?
        if let explicit = options.port {
            port = explicit
        } else if let overridden = options.command {
            port = Self.vmDevPort(inScript: overridden) ?? detection.port
        } else {
            port = detection.port
        }
        let sync = options.sync ?? (options.localDirArgument != nil || detection.kind != "none")

        // The layout: a caller's document, validated here exactly as `vm layout apply` does
        // it (exit 2 with the JSON path), or the built-in one. Either way the surfaces'
        // `cwd` is the remote path, resolved by the shim against the machine user's home.
        let documentData: Data
        if let layoutFile = options.layoutFile {
            let path = resolvePath(layoutFile)
            guard let data = FileManager.default.contents(atPath: path) else {
                throw CLIError(message: "vm dev: cannot read layout file \(path)")
            }
            do {
                _ = try Self.parseVMLayoutDocument(data)
            } catch let error as VMLayoutDocumentError {
                throw CLIError(message: "vm dev: invalid layout document: \(error.description)", exitCode: 2)
            }
            documentData = data
        } else {
            let document = Self.vmDevLayoutDocument(name: workspaceName, remote: remote, command: command, port: port)
            documentData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        }
        let documentObject = (try? JSONSerialization.jsonObject(with: documentData)) as? [String: Any]

        let devLine: String
        if let command {
            devLine = "dev: \(command)\(port.map { " (port \($0))" } ?? "")"
        } else {
            devLine = "dev: nothing to run — \(detection.detail); shell pane only\(port.map { " (browser tab on port \($0))" } ?? "")"
        }

        if options.dryRun {
            if jsonOutput {
                var plan: [String: Any] = [
                    "dry_run": true,
                    "machine": machine,
                    "local": localURL.path,
                    "remote": remote,
                    "workspace_name": workspaceName,
                    "sync": sync,
                    "open": !options.noOpen,
                    "detected": ["kind": detection.kind, "detail": detection.detail],
                    "command": Self.vmDevJSON(command),
                    "port": Self.vmDevJSON(port),
                    "layout": Self.vmDevJSON(documentObject),
                ]
                if options.layoutFile != nil { plan["layout_file"] = resolvePath(options.layoutFile ?? "") }
                print(jsonString(plan))
                return
            }
            print("plan: \(localURL.path) → \(machine):\(remote)")
            print("plan: sync \(sync ? "on" : "off")\(sync ? "" : " (pass --sync to push the folder)")")
            print("plan: detected \(detection.kind) — \(detection.detail)")
            print("plan: \(devLine)")
            print("plan: workspace \(workspaceName) (get-or-create), \(options.layoutFile == nil ? "built-in dev layout" : "layout from \(options.layoutFile ?? "")"), \(options.noOpen ? "not opened here" : "opened here")")
            if let documentObject {
                print(jsonString(documentObject))
            }
            return
        }

        // 1. route: the machine must exist and answer; then this folder is bound to it so
        // `vm run --sync` / `vm agent --sync` from here keep landing on the same warm tree.
        let statusResponse = try client.sendV2(method: "vm.status", params: ["id": machine], responseTimeout: 60)
        let status = ((statusResponse["status"] as? String) ?? "unknown").lowercased()
        guard !["destroyed", "deleted", "failed", "error"].contains(status) else {
            throw CLIError(message: "vm dev: \(machine) is \(status); pick a live machine (cmux vm ls)")
        }
        Self.saveVMRunBinding(workKey: Self.vmRunWorkKey(forDirectory: localURL.path), machine: machine)
        var lines: [String] = ["route ok: \(machine) status=\(status) (bound to \(localURL.path))"]
        if !jsonOutput { Self.vmDevFlush(&lines) }

        // 2. sync: the exact `vm push` path (defaults, excludes, digest check). Its own
        // summary goes to stderr (quiet) so stdout stays the step log.
        var syncedFiles: Int?
        if sync {
            try runVMPushCommand(rest: [machine, localURL.path, remote], client: client, jsonOutput: false, quiet: true)
            let count = Self.vmDevCountLocalFiles(in: localURL)
            syncedFiles = count
            lines.append("synced \(count) file\(count == 1 ? "" : "s") → \(machine):\(remote)")
        } else {
            lines.append("sync skipped → using \(machine):\(remote) as it is")
        }
        lines.append(devLine)
        if !jsonOutput { Self.vmDevFlush(&lines) }

        // 3. workspace discovery: refresh the authoritative machine catalog before deciding
        // whether to reuse a workspace. New workspaces are created by the layout shim with
        // --name, because vm.workspace_new intentionally preserves its starter-shell contract.
        let catalog = try client.sendV2(
            method: "vm.tree",
            params: ["id": machine, "refresh": true],
            responseTimeout: 120
        )
        guard let resources = catalog["resources"] as? [[String: Any]],
              let machinePayload = VMRemoteWorkspaceResolver().vmMachinePayload(machine, from: catalog) else {
            throw CLIError(message: "vm dev: workspace state for \(machine) is unavailable; reconnect and retry")
        }
        var remoteWorkspace: String?
        let existing: Bool
        switch VMRemoteWorkspaceResolver().resolveVMRemoteWorkspaceSelector(workspaceName, in: machinePayload) {
        case .resolved(let id):
            remoteWorkspace = id
            existing = true
        case .notFound:
            remoteWorkspace = nil
            existing = false
        case .ambiguous(let ids):
            throw CLIError(message: "vm dev: several workspaces on \(machine) are named '\(workspaceName)' (\(ids.joined(separator: ", "))); choose a unique --name or remove the duplicates")
        case .unavailable:
            throw CLIError(message: "vm dev: workspace state for \(machine) is unavailable; reconnect and retry")
        }
        if let remoteWorkspace {
            lines.append("workspace \(workspaceName) = \(remoteWorkspace) (existing)")
        }

        // 4. layout: only into an EMPTY workspace (the shim refuses otherwise). A reused
        // workspace that already has panes keeps them — running `vm dev` twice must not
        // stack a second dev server next to the first.
        var layoutApplied = false
        var terminals: [String: String] = [:]
        var applyPayload: [String: Any]?
        let existingInfo = existing
            ? try vmDevWorkspaceInfo(
                resources: resources,
                machine: machine,
                remoteWorkspace: remoteWorkspace ?? ""
            )
            : nil
        let alreadyBuilt = existingInfo?.hasPanes == true
        if alreadyBuilt {
            terminals = existingInfo?.terminalIDs ?? [:]
            lines.append("layout kept: \(remoteWorkspace ?? "?") already has panes (close it with `cmux vm workspace rm \(machine) \(remoteWorkspace ?? "?")` to rebuild)")
        } else {
            let result = try vmDevRunShim(
                Self.vmLayoutApplyCommand(
                    documentJSON: documentData,
                    workspace: existing ? remoteWorkspace : nil,
                    name: existing ? nil : workspaceName,
                    cwd: nil,
                    reuse: true
                ),
                machine: machine,
                client: client,
                timeoutMs: Self.vmDevApplyExecTimeoutMs
            )
            applyPayload = Self.jsonObject(fromShimOutput: result.stdout)
            for warning in (applyPayload?["warnings"] as? [String]) ?? [] {
                cliWriteStderr("warning: \(warning)\n")
            }
            let appliedWorkspace = (applyPayload?["workspace_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let appliedWorkspace, !appliedWorkspace.isEmpty else {
                throw CLIError(message: "vm dev: layout apply returned no workspace id for \(workspaceName) on \(machine)")
            }
            if remoteWorkspace == nil {
                // Keep the output and follow-up open operation tied to the workspace the
                // shim actually created, rather than guessing from the pre-apply catalog.
                remoteWorkspace = appliedWorkspace
                lines.append("workspace \(workspaceName) = \(appliedWorkspace) (new)")
            }
            terminals = Self.vmDevTerminalIDs(fromApplyPayload: applyPayload)
            layoutApplied = true
            let panes = ((applyPayload?["panes"] as? [[String: Any]]) ?? []).count
            lines.append("layout applied: \(panes) pane\(panes == 1 ? "" : "s")\(terminals["dev"].map { ", dev terminal \($0)" } ?? "")\(terminals["shell"].map { ", shell terminal \($0)" } ?? "")")
        }
        if !jsonOutput { Self.vmDevFlush(&lines) }

        // 5. open here with the same geometry; then the public URL for the port.
        var openedPayload: [String: Any]?
        if !options.noOpen {
            guard let remoteWorkspace else {
                throw CLIError(message: "vm dev: no remote workspace id is available to open")
            }
            openedPayload = try vmDevOpenWorkspace(machine: machine, remoteWorkspace: remoteWorkspace, client: client)
            let local = (openedPayload?["workspace_id"] as? String) ?? "?"
            lines.append("opened locally: workspace \(local)")
        } else {
            guard let remoteWorkspace else {
                throw CLIError(message: "vm dev: no remote workspace id is available to stage")
            }
            lines.append("staged: cmux vm workspace open \(machine) \(remoteWorkspace)")
        }
        var publicURL: String?
        if let port {
            do {
                let payload = try client.sendV2(method: "vm.open_port", params: ["id": machine, "port": port], responseTimeout: 90)
                publicURL = (payload["open_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (payload["url"] as? String)
            } catch {
                publicURL = nil
            }
            if let publicURL {
                lines.append("url: \(publicURL)")
            } else {
                lines.append("preview: cmux vm open \(machine) \(port)   (the URL is minted once the machine answers)")
            }
        }

        if jsonOutput {
            var payload: [String: Any] = [
                "machine": machine,
                "workspace_id": Self.vmDevJSON(remoteWorkspace),
                "workspace_name": workspaceName,
                "existing": existing,
                "local": localURL.path,
                "remote": remote,
                "synced": sync,
                "detected": ["kind": detection.kind, "detail": detection.detail],
                "command": Self.vmDevJSON(command),
                "port": Self.vmDevJSON(port),
                "url": Self.vmDevJSON(publicURL),
                "terminals": ["dev": Self.vmDevJSON(terminals["dev"]), "shell": Self.vmDevJSON(terminals["shell"])],
                "layout_applied": layoutApplied,
                "opened": openedPayload != nil,
            ]
            if let syncedFiles { payload["synced_files"] = syncedFiles }
            if let local = openedPayload?["workspace_id"] as? String { payload["local_workspace_id"] = local }
            if let applyPayload { payload["layout"] = applyPayload }
            print(jsonString(payload))
            return
        }
        Self.vmDevFlush(&lines)
        if let dev = terminals["dev"] {
            print("next: cmux vm terminal output \(machine) \(dev)      # the dev server's log so far")
        }
        if let shell = terminals["shell"] {
            print("next: cmux vm terminal send \(machine) \(shell) 'ls' --keys enter      # run something in the shell pane")
        }
        if terminals.isEmpty {
            print("next: cmux vm tree \(machine)      # terminal ids for `cmux vm terminal output|send`")
        }
    }

    /// JSON needs an explicit null where Swift has nil.
    private static func vmDevJSON(_ value: Any?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func vmDevFlush(_ lines: inout [String]) {
        for line in lines { print(line) }
        lines.removeAll()
    }

    /// Files a directory push carries, counted with the same default exclusions
    /// `vm push` applies (tar `--exclude <name>` matches the entry name anywhere).
    static func vmDevCountLocalFiles(in directory: URL) -> Int {
        let excluded = Set(vmPushDefaultExcludes)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if excluded.contains(url.lastPathComponent) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private func vmDevWorkspaceInfo(
        resources: [[String: Any]],
        machine: String,
        remoteWorkspace: String
    ) throws -> (hasPanes: Bool, terminalIDs: [String: String])? {
        let terminalIDs = Self.vmDevTerminalIDs(
            fromCatalogResources: resources,
            machine: machine,
            workspaceID: remoteWorkspace
        )
        let hasPanes: Bool
        switch VMRemoteWorkspaceResolver().resolveVMRemoteWorkspaceTerminal(
            resources,
            machine: machine,
            workspaceID: remoteWorkspace
        ) {
        case .resolved, .ambiguous:
            hasPanes = true
        case .unavailable(let selector):
            throw CLIError(message: "vm dev: terminal placement for workspace \(remoteWorkspace) on \(machine) is unavailable (resource \(selector)); reconnect and retry")
        case .none:
            // Exited panes are omitted by the live resolver, but still occupy
            // the daemon workspace. The shared helper checks them and fails
            // closed when their placement is unknown.
            hasPanes = try Self.vmDevWorkspaceHasPlacedTerminals(
                resources,
                machine: machine,
                workspaceID: remoteWorkspace
            )
        }
        return (hasPanes: hasPanes, terminalIDs: terminalIDs)
    }

    private struct VMDevShimResult {
        let stdout: String
        let stderr: String
    }

    /// One `vm.exec` of the machine's `cmux` shim with the `vm layout apply` contract: a
    /// shim too old for the verb is explained, a non-zero exit carries the shim's own
    /// message and small exit codes through, warnings on stderr are forwarded.
    /// (Same rules as CMUXCLI+VMLayoutEnv's file-private `runVMShim`.)
    private func vmDevRunShim(_ command: String, machine: String, client: SocketClient, timeoutMs: Int) throws -> VMDevShimResult {
        let response = try client.sendV2(
            method: "vm.exec",
            params: ["id": machine, "command": command, "timeout_ms": timeoutMs],
            responseTimeout: TimeInterval(timeoutMs) / 1000 + 30
        )
        let stdout = (response["stdout"] as? String) ?? ""
        let stderr = (response["stderr"] as? String) ?? ""
        let exitCode = (response["exit_code"] as? Int) ?? -1
        if Self.vmShimPredatesSupport(stdout: stdout, stderr: stderr) {
            throw CLIError(message: Self.vmShimOutdatedMessage(machine: machine, feature: "layout"))
        }
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = detail.isEmpty ? (fallback.isEmpty ? "cmux layout apply failed on \(machine) (exit \(exitCode))" : fallback) : detail
            let passthrough: Int32 = (1...3).contains(exitCode) ? Int32(exitCode) : 1
            throw CLIError(message: "vm dev: \(text)", exitCode: passthrough)
        }
        if !stderr.isEmpty {
            cliWriteStderr(stderr.hasSuffix("\n") ? stderr : stderr + "\n")
        }
        return VMDevShimResult(stdout: stdout, stderr: stderr)
    }

    /// The geometry-honoring open (`vm.workspace_open`, what the sidebar row and
    /// `cmux vm workspace open` use) for a workspace the shim built moments ago: re-sync
    /// the machine first (`vm.tree {refresh}`), then open, retrying briefly while the Mac
    /// catalog catches up with the daemon's event stream. (Same policy as
    /// CMUXCLI+VMLayoutEnv's file-private `openAppliedVMWorkspace`.)
    private func vmDevOpenWorkspace(machine: String, remoteWorkspace: String, client: SocketClient) throws -> [String: Any] {
        _ = try client.sendV2(method: "vm.tree", params: ["id": machine, "refresh": true], responseTimeout: 120)
        var lastFailure = ""
        for attempt in 1...Self.vmLayoutOpenAttempts {
            do {
                let payload = try client.sendV2(
                    method: "vm.workspace_open",
                    params: ["id": machine, "workspace_id": remoteWorkspace],
                    responseTimeout: 240
                )
                let opened = (payload["opened"] as? Int) ?? 0
                let empty = (payload["empty"] as? Bool) ?? false
                if opened > 0, !empty { return payload }
                lastFailure = empty ? "the Mac still sees workspace \(remoteWorkspace) as empty" : "nothing opened"
            } catch let error as CLIError where Self.vmWorkspaceNotYetVisible(error) {
                lastFailure = error.message
            }
            if attempt < Self.vmLayoutOpenAttempts {
                Thread.sleep(forTimeInterval: Self.vmLayoutOpenRetryDelay)
            }
        }
        throw CLIError(message: "vm dev: the layout is built in workspace \(remoteWorkspace) on \(machine), but it could not be opened here yet (\(lastFailure)). Open it with: cmux vm workspace open \(machine) \(remoteWorkspace)")
    }
}
