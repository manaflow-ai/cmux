import CmuxNextDaemon
import Foundation

/// A temporary, unverified app using the public JS ABI and an explicitly granted read scope.
struct MachineCatalogAppPackage {
    let id = "local/inventory"
    let family = "local.inventory"

    func write(to root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifestVersion": 2, "id": id, "name": "Inventory proof", "version": "1.0.0", "description": "Isolated integration fixture",
            "engines": ["cmux": "^2.0"], "runtime": ["main": "dist/main.js"], "catalog": "catalog.json",
            "scopes": ["machine:read": "Read admitted machines"],
            "optionalScopes": ["agent_cli:read": "Read a selected owner's cached CLI inventory"],
            "files": ["dist/", "catalog.json"],
        ]
        let operations = ["discover", "inventory", "watch", "next", "unwatch"].map { verb -> [String: Any] in
            ["name": "\(family).\(verb)", "owner": "app:\(id)", "class": "read", "risk": "read",
             "idempotency": "forbidden", "input": ["type": "object"], "docs": "Integration fixture", "since": "1.0.0", "export": verb]
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("cmux-app.json"))
        try JSONSerialization.data(withJSONObject: ["family": family, "operations": operations], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("catalog.json"))
        let script = """
        var off, nextNotice;
        var __cmuxAppExports = {
          discover: async function () { return await cmux.call("machine.list", {catalog: true}); },
          inventory: async function (args) { return await cmux.call("agent_cli.list", args); },
          watch: function () {
            if (off) off();
            nextNotice = new Promise(function (resolve) { off = cmux.events.on("agent_cli.changed", resolve); });
            return {};
          },
          next: async function () { return await nextNotice; },
          unwatch: function () { if (off) off(); off = null; return {}; }
        };
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("dist/main.js"))
    }
}
