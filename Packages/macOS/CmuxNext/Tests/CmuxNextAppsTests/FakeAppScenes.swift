/// Static sample scenes the fake supervisor sends for a mount: a few rows
/// shaped like each sample app's output, so the demo and the store render
/// without an app host. Previews and installs show the same rows.
nonisolated enum FakeAppScenes {
    static func scene(for record: AppRecord, interface: String, preview: Bool) -> [AppSceneOp] {
        if interface == AppImplementation.status {
            return [
                .create(id: "s", type: "HStack", props: ["spacing": 4]),
                .create(id: "i", type: "Icon", props: ["symbol": "circle.fill", "size": 7, "color": "attention"]),
                .create(id: "t", type: "Text", props: ["text": "1 blocked", "font": "caption"]),
                .children(id: "s", children: ["i", "t"]), .root(id: "s"),
            ]
        }
        let rows: [(String, String, String)] = switch record.id {
        case "cmux/github-prs": [("arrow.triangle.pull", "Port runtime to QuickJS", "review requested"),
                                 ("arrow.triangle.pull", "Sidebar sections v2", "draft")]
        case "cmux/running-agents": [("circle.fill", "Fix flaky sidebar test", "blocked"), ("circle.dotted", "Review PR 16740", "working")]
        default: [("circle.fill", "2 working", "1 blocked")]
        }
        var ops: [AppSceneOp] = [.create(id: "root", type: "VStack", props: ["spacing": 0])]
        for (index, row) in rows.enumerated() {
            ops.append(.create(id: "r\(index)", type: "Row", props: ["symbol": .string(row.0), "title": .string(row.1),
                                                                    "subtitle": .string(row.2), "onTap": true]))
        }
        ops.append(.children(id: "root", children: rows.indices.map { "r\($0)" }))
        ops.append(.root(id: "root"))
        return ops
    }
}
