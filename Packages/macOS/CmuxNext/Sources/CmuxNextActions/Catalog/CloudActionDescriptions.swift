// What each Cloud action does, what it needs and what a CLI or agent run gets
// back (`ActionDescriptor.description`). English, like the MCP tool text these
// head: an agent reads them in `cmux action describe` and in the cmux MCP
// server's tool list; the GUI does not show them. Each one says what the
// action's handler does (CmuxNextApp/Handlers/CloudHandlers*.swift,
// CloudGitHubHandlers.swift, Cloud/CloudMove*.swift); change it with the handler.
// A command named here must be one the CLI offers (CloudActionDescriptionTests).

nonisolated enum CloudActionDescriptions {
    static let text: [ActionID: String] = [
        "newCloudWorkspace": """
            Opens a workspace on the Cloud machine the focused window shows, else the only one. A connected \
            machine gets a new workspace; one not connected is connected (a paused one resumes) and its first \
            workspace opens. When neither picks a machine (none, or several and none focused) it creates one, \
            which may ask the person first. Answers at once with no ids: \
            `cmux cloud new-terminal-on-machine --target machine:<id>` returns a workspace_id.
            """,
        "newCloudMachine": """
            Creates a Cloud machine; returns machine_id, title, status and target once the server has it. \
            After 30 s it answers pending: true and the create goes on: check `cmux cloud list-machines` \
            before another. Options: --size small|medium|large|xlarge, --name, --persistent (no idle \
            pause), --bootstrap-script FILE (--bootstrap lane for a lane host), --machine-config FILE (a \
            .cmux/machine.toml), answering bootstrap, machine_config and enrollment. An agent's create may \
            ask the person first.
            """,
        "palette.cloud.fork": """
            Forks the machine (--target machine:<id>) into a new machine. Answers at once with no id; the \
            new machine shows in `cmux cloud list-machines` when the fork is done.
            """,
        "palette.cloud.snapshot": """
            Takes a snapshot of the machine (--target machine:<id>) and returns machine_id and snapshot_id. \
            A snapshot that takes longer than 30 s answers pending: true and finishes on its own.
            """,
        "palette.cloud.restore": """
            Starts a new machine from a snapshot: --snapshot <snapshot id>, from \
            `cmux cloud snapshot-machine --target machine:<id>`. With no Cloud workspace focused, also pass \
            --target machine:<id> of any machine; the new machine does not depend on it. Answers at once with no \
            id; the machine shows in `cmux cloud list-machines` when it is up.
            """,
        "palette.cloud.promoteTemplate": """
            Saves the machine (--target machine:<id>) as a template: a snapshot named \
            template-<first 12 characters of the machine id>-<Unix seconds>, which \
            `cmux cloud restore-machine --target machine:<id> --snapshot <snapshot id>` starts new machines from. \
            Returns machine_id and snapshot_id; after 30 s it answers pending: true and finishes on its own.
            """,
        "palette.cloud.status": """
            Reads the machine's state and use (--target machine:<id>) and returns machine_id, title, state, \
            status, CPU, memory and disk use, its address, and its hourly rate and estimated cost when the \
            server reports them.
            """,
        "palette.cloud.ports": """
            Lists the TCP ports listening on the machine (--target machine:<id>) and returns machine_id and \
            ports (comma-separated). Needs the machine connected: resume a paused one first with \
            `cmux cloud resume-machine --target machine:<id>`.
            """,
        "palette.cloud.tools": """
            Shows the machine's login shell, where zsh, git, gh, htop, btop, node, bun and python3 are \
            installed, and the zsh and gh versions. Not a CLI verb: \
            `cmux cloud exec --target machine:<id> --command '...'` runs such checks.
            """,
        "palette.cloud.handoff": """
            Returns text for handing the machine (--target machine:<id>) to another person or agent (its \
            name, id, provider and live status), with machine_id and status.
            """,
        "cloudMove": """
            Moves a chat tab of this Mac to a Cloud machine: copies the chat's folder (--path, else the \
            chat's own) to the machine (--machine machine:<id>, else a connected one, else any, else a new \
            one), moves the chat there and opens it, keeping its session and history. An agent can ask only \
            for its own chat, and its run ignores --path and --machine: it shows the person a card in that \
            chat (Move, Not now, Always) and moves only when they click Move or Always, except that a chat \
            in a folder the person already answered Always for moves at once.
            """,
        "cloudBringBack": """
            Brings a chat that a move from this Mac put on a Cloud machine back to this Mac: pulls its \
            folder, moves the chat back, opens it here and closes the machine's tab. Only a person runs it: \
            an agent's run (MCP, or the CLI from an agent's chat) is refused.
            """,
        "cloudSSH": """
            Opens a new terminal tab in the machine's first workspace (--target machine:<id>), resuming a \
            paused machine first, and returns machine_id, workspace_id and the tab's surface_id (terminal_id \
            when known). The window shows it only with --focus. When the run takes longer than 30 s it answers \
            machine_id and pending: true, and the tab still opens.
            """,
        "cloudExec": """
            Runs a shell command on the machine through the Cloud API and returns machine_id, exit_code, \
            stdout and stderr; no tab opens. Needs --target machine:<id> and --command; the command stops \
            after 25 s. A person's run from the palette types it into a new terminal tab instead.
            """,
        "cloudSetupGitHub": """
            Copies this Mac's git user.name and user.email to the machine (--target machine:<id>) and starts \
            a GitHub CLI sign-in there; no token leaves this Mac. Returns ok, gh_status (logged_in, pending, \
            missing or failed), the identity it set and, while the sign-in waits, device_code and \
            verification_uri for the person to approve; --focus also opens that page.
            """,
        "cloudEnrollMachine": """
            Makes the machine (--target machine:<id>) an ssh host and an acpmux peer of this Mac: authorizes \
            --ssh-key (default ~/.ssh/id_ed25519.pub) for its cmux user, pins its host key, writes a Host \
            block in ~/.ssh/cmux-cloud/config named --name that dials through this app's tunnel, then peers \
            acpmux. Returns ssh_host, address, steps_done, steps_pending, rerun_command and registry_command.
            """,
        "cloudFilesList": """
            Lists a directory on the machine (--target machine:<id> --path /absolute/dir) and returns path, \
            count and text with one line per entry (d for a directory, - for a file, with its size).
            """,
        "cloudFileRead": """
            Reads a file on the machine (--target machine:<id> --path /absolute/file) and returns path, \
            encoding and the contents in text: UTF-8 as is, anything else as base64 (also in data_base64), \
            with size when known.
            """,
        "cloudFileWrite": """
            Writes --contents as UTF-8 text to a file on the machine (--target machine:<id> --path \
            /absolute/file), replacing it in one step. Returns no fields.
            """,
        "cloudFileMkdir": """
            Creates a directory on the machine (--target machine:<id> --path /absolute/dir). Returns no fields.
            """,
        "cloudFileRemove": """
            Removes a file on the machine (--target machine:<id> --path /absolute/file). Destructive: a CLI \
            or agent run needs --confirm. Returns no fields.
            """,
        "cloudFileStat": """
            Reads a file's details on the machine (--target machine:<id> --path /absolute/path) and returns \
            path, kind, and size and mode (octal) when known.
            """,
        "cloudPrepareSCP": """
            Authorizes an SSH public key (--public-key, the key's text) for file transfer to the machine \
            (--target machine:<id>) and returns host, port, user, host_key and expires_at (Unix seconds) \
            for scp or sftp.
            """,
        "cloudTunnelAttach": """
            Attaches this Mac's Cloud tunnel to a private network. The network id (from \
            `cmux cloud network-list`) goes in the path argument: --arg path=<network id>. Returns no fields.
            """,
        "cloudTunnelDetach": """
            Detaches this Mac's Cloud tunnel from a private network. The network id goes in the path \
            argument: --arg path=<network id>. Returns no fields.
            """,
        "cloudTunnelRotateKey": """
            Replaces the client public key of this Mac's Cloud tunnel with --public-key. Returns no fields.
            """,
        "cloudNetworkList": """
            Lists the account's Cloud networks and returns count and text with one line per network: its \
            id, scope and CIDR.
            """,
        "cloudFirewallList": """
            Lists the account's Cloud firewall rules and returns count and text with one line per rule: its \
            id and description (else its action).
            """,
        "cloudFirewallGet": """
            Reads one Cloud firewall rule and returns id, action and text. The rule id goes in the path \
            argument: --arg path=<rule id>.
            """,
        "cloudFirewallCreate": """
            Creates a Cloud firewall rule from JSON in the path argument: \
            --arg 'path={"source":{...},"destination":{...},"description":"..."}'. Returns no fields.
            """,
        "cloudFirewallDelete": """
            Deletes a Cloud firewall rule (--arg path=<rule id>). Destructive: a CLI or agent run needs \
            --confirm. Returns no fields.
            """,
        "cloudDomainList": """
            Lists the account's Cloud domains and returns count and text with one line per domain: its \
            hostname and its verification and certificate states.
            """,
        "cloudPublicationList": """
            Lists the account's Cloud publications and returns count and text with one line per \
            publication: its hostname, state and access mode.
            """,
        "cloudProvisionAPI": """
            Provisions an API on the machine (--target machine:<id>): publishes --port behind cmux \
            sign-in under a generated https hostname and mints an API key for it, in one call. Returns url, \
            publication_id, api_key_id, key and cookie. API clients send the key as the cookie \
            (__Host-cmux-api-key=<key>), which the machine never receives; the key is answered this one time. \
            Running it again for the same port reuses the URL and mints another key. Optional --name names \
            the key.
            """,
        "cloudAPIKeyList": """
            Lists the live API keys of a Cloud publication (--arg path=<publication id or hostname>) and \
            returns count and text with one line per key: its id, name and last four characters.
            """,
        "cloudAPIKeyRevoke": """
            Revokes an API key (--arg path=<publication id or hostname> --arg key=<key id>); requests with \
            it are refused from the next one on. Destructive: a CLI or agent run needs --confirm. Returns \
            api_key_id and revoked_at.
            """,
        "cloudListMachines": """
            Returns the app's Cloud machines: loaded, count, account.signed_in and machines, each with \
            machine_id, target (machine:<id>), title, status, owner and created_at. loaded false means the \
            list is not known yet (signed out, or still loading after 25 s with pending: true), not that \
            there are none.
            """,
        "cloudNewTerminal": """
            Opens a new workspace with a terminal on the machine (--target machine:<id>), resuming a paused \
            machine first, and returns machine_id, workspace_id and, when known, the terminal's surface_id. \
            With --workspace <id> (a workspace_id it returned) it adds a terminal tab to that workspace of the \
            machine instead and returns its surface_id; an id the machine does not have is refused. The window \
            shows it only with --focus. When the whole run takes longer than 30 s it answers machine_id and \
            pending: true, and the terminal still opens.
            """,
        "cloudOpenMachine": """
            Shows the machine's first workspace in the window (creating one when it has none), connecting \
            it and resuming it when paused. Not a CLI verb: \
            `cmux cloud new-terminal-on-machine --target machine:<id> --focus` opens and shows a workspace.
            """,
        "cloudRenameMachine": """
            Renames the machine (--target machine:<id> --name <name>; an empty name clears it). Answers at \
            once, before the rename is done. Without --name it asks the person for the name in the app, so a \
            script or agent passes --name.
            """,
        "cloudKillMachine": """
            Deletes the machine (--target machine:<id>) and everything on it. Destructive: a CLI or agent \
            run needs --confirm. Answers at once, before the delete is done.
            """,
        "cloudPauseMachine": """
            Pauses the machine (--target machine:<id>); the run ends when the server has paused it. Returns \
            no fields. `cmux cloud resume-machine --target machine:<id>` starts it again.
            """,
        "cloudResumeMachine": """
            Resumes a paused machine (--target machine:<id>); the run ends when the server has resumed it. \
            Returns no fields.
            """,
        "cloudCopyLink": """
            Opens a port of the machine (--port) through cmux Cloud and copies its link to the clipboard. \
            Not a CLI verb.
            """,
        "cloudCopyPort": """
            Copies http://<machine address>:<port> (--port) to the clipboard. Not a CLI verb.
            """,
        "cloudCopyMachineID": """
            Copies the machine's id to the clipboard. Not a CLI verb: `cmux cloud list-machines` returns ids.
            """,
        "cloudApplyMachineConfig": """
            Applies a .cmux/machine.toml (env, secret names, setup) to the machine (--target machine:<id>): \
            --machine-config FILE uploads one, else the machine takes its --repo checkout's or the last \
            upload. Answers status (started, running or failed) at once; the machine writes the outcome to \
            ~/.cmux/machine-config/status.json, read with `cmux cloud file-read --target machine:<id> --path …`.
            """,
        "cloudDeliverSecrets": """
            Sends the values of the secret names the machine's .cmux/machine.toml declares (--target \
            machine:<id>, --repo OWNER/NAME for repo-scoped ones) from this Mac's Keychain to the machine \
            over its daemon link, never the Cloud API. Returns status (delivered, unchanged or pending), \
            delivered and missing names. Values are stored with cmux cloud secret set NAME.
            """,
        "cloudResizeMachine": """
            Resizes the machine (--target machine:<id> --size small, medium, large or xlarge: 2 vCPU and \
            4 GB, 4 and 8, 8 and 16, or 16 and 24). Answers at once, before the resize is done.
            """,
        "cloudSetIdlePause": """
            Sets how long the machine (--target machine:<id>) may sit idle (nothing attached, running or \
            forwarded) before cmux Cloud pauses it: --minutes off, 15, 30, 60 or 120. Returns machine_id \
            and idle_pause_minutes (0 for off).
            """,
        "palette.cloud.deleteSnapshot": """
            Deletes a snapshot of the machine (--target machine:<id> --snapshot <snapshot id>). Destructive: \
            a CLI or agent run needs --confirm. Returns no fields.
            """,
        "cloudDiagnostics": """
            Checks the Cloud sign-in, the backend and each machine's link, and returns summary (the first \
            thing that needs attention, else that all is well) and details (a JSON report with no secrets).
            """,
        "openTeamPicker": """
            Switches the active team (--team, its id or name) that Cloud machines are listed and created \
            under. Not a CLI verb.
            """,
        "palette.auth.signIn": """
            Opens the cmux sign-in page, which Cloud needs. Answers at once, before the person signs in; \
            refused when already signed in. Not offered to MCP: a person signs in.
            """,
        "palette.auth.signOut": """
            Signs this Mac out of cmux and Cloud. Answers at once. Not offered to MCP.
            """,
        "palette.mobileConnect": """
            Opens the Mobile Pairing page in the active window, which walks the person through pairing an \
            iPhone and shows a QR code. It takes focus only with --focus; refused when no window is open.
            """,
    ]
}
