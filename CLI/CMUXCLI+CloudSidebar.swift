import Foundation

extension CMUXCLI {
    static var cloudSidebarUsage: String {
        CMUXDiffViewerLocalization.string("cli.vm.sidebar.usage", defaultValue: """
        cmux vm tree --sidebar [list|pin|unpin|up|down|before|after] [node-id] [target-id]
        Organize this Mac's Cloud sidebar. Use list to find row IDs; before/after require a target in the same group and pin section. Sessions and pane layouts are unchanged.
        """)
    }

    func runCloudSidebarCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") { print(Self.cloudSidebarUsage); return }
        let args = rest.filter { !["--sidebar", "--json"].contains($0) }
        let verb = args.first ?? "list"
        let counts = ["list": 1, "pin": 2, "unpin": 2, "up": 2, "down": 2, "before": 3, "after": 3]
        guard let count = counts[verb], args.count == count || args.isEmpty else {
            throw CLIError(message: Self.cloudSidebarUsage)
        }
        var params: [String: Any] = ["sidebar": true, "action": verb]
        if args.count > 1 { params["node_id"] = args[1] }
        if args.count > 2 { params["target_id"] = args[2] }
        let result = try client.sendV2(method: "vm.tree", params: params)
        if jsonOutput { print(jsonString(result)); return }
        func lines(_ rows: [[String: Any]], depth: Int) {
            for row in rows {
                let pin = row["pinned"] as? Bool == true ? "📌 " : ""
                print(String(repeating: "  ", count: depth) + pin + (row["title"] as? String ?? "") + "  " + (row["id"] as? String ?? ""))
                lines(row["children"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        lines(result["rows"] as? [[String: Any]] ?? [], depth: 0)
    }
}
