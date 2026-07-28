import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareOutboundMessageValidatorTests {
    private let validator = WorkspaceShareOutboundMessageValidator()

    @Test
    func `Chat and titles truncate on Unicode-scalar boundaries`() throws {
        let longText = String(repeating: "界", count: 2_000)
        let prepared = try #require(
            validator.prepare(.chat(text: longText, bubble: nil))
        )
        guard case .chat(let text, bubble: nil) = prepared else {
            Issue.record("Expected a normalized chat")
            return
        }
        #expect(text.utf8.count == 3_999)
        #expect(String(text.unicodeScalars.last!) == "界")

        let title = String(repeating: "🙂", count: 200)
        let shared = try #require(
            validator.prepare(
                .shared([ShareSharedWorkspace(id: "workspace", title: title)])
            )
        )
        guard case .shared(let workspaces) = shared else {
            Issue.record("Expected normalized workspace metadata")
            return
        }
        #expect(workspaces[0].title.utf8.count == 512)
        #expect(workspaces[0].title.unicodeScalars.count == 128)
    }

    @Test
    func `Layout accepts pane bound and rejects the next pane`() throws {
        let accepted = ShareWorkspaceLayout(
            ws: "workspace",
            tree: balancedTree(
                leaves: ShareProtocolConstants.maximumLayoutPanes,
                start: 0
            )
        )
        #expect(validator.prepare(.layout(accepted)) != nil)

        let rejected = ShareWorkspaceLayout(
            ws: "workspace",
            tree: balancedTree(
                leaves: ShareProtocolConstants.maximumLayoutPanes + 1,
                start: 0
            )
        )
        #expect(validator.prepare(.layout(rejected)) == nil)
    }

    @Test
    func `Layout accepts depth bound and rejects the next depth`() {
        let accepted = ShareWorkspaceLayout(
            ws: "workspace",
            tree: skewedTree(depth: ShareProtocolConstants.maximumLayoutDepth)
        )
        #expect(validator.prepare(.layout(accepted)) != nil)

        let rejected = ShareWorkspaceLayout(
            ws: "workspace",
            tree: skewedTree(
                depth: ShareProtocolConstants.maximumLayoutDepth + 1
            )
        )
        #expect(validator.prepare(.layout(rejected)) == nil)
    }

    @Test
    func `Hello requires matching unique workspace and valid geometry`() {
        let shared = [ShareSharedWorkspace(id: "workspace", title: "Demo")]
        let matching = [
            ShareWorkspaceLayout(
                ws: "workspace",
                tree: .pane(
                    pane: "pane",
                    content: "terminal",
                    cols: 80,
                    rows: 24,
                    title: nil
                )
            ),
        ]
        #expect(
            validator.prepare(.hello(shared: shared, layouts: matching)) != nil
        )
        #expect(
            validator.prepare(
                .hello(
                    shared: shared,
                    layouts: [ShareWorkspaceLayout(ws: "other", tree: nil)]
                )
            ) == nil
        )
        #expect(
            validator.prepare(
                .layout(
                    ShareWorkspaceLayout(
                        ws: "workspace",
                        tree: .split(
                            axis: "h",
                            ratio: .nan,
                            a: .pane(
                                pane: "a",
                                content: "terminal",
                                cols: nil,
                                rows: nil,
                                title: nil
                            ),
                            b: .pane(
                                pane: "b",
                                content: "terminal",
                                cols: nil,
                                rows: nil,
                                title: nil
                            )
                        )
                    )
                )
            ) == nil
        )
    }

    private func balancedTree(leaves: Int, start: Int) -> ShareLayoutNode {
        if leaves == 1 {
            return .pane(
                pane: "pane-\(start)",
                content: "terminal",
                cols: 80,
                rows: 24,
                title: "Terminal"
            )
        }
        let leftCount = leaves / 2
        return .split(
            axis: "h",
            ratio: 0.5,
            a: balancedTree(leaves: leftCount, start: start),
            b: balancedTree(
                leaves: leaves - leftCount,
                start: start + leftCount
            )
        )
    }

    private func skewedTree(depth: Int) -> ShareLayoutNode {
        if depth == 1 {
            return .pane(
                pane: "pane-depth-1",
                content: "terminal",
                cols: nil,
                rows: nil,
                title: nil
            )
        }
        return .split(
            axis: "v",
            ratio: 0.5,
            a: .pane(
                pane: "pane-depth-\(depth)",
                content: "terminal",
                cols: nil,
                rows: nil,
                title: nil
            ),
            b: skewedTree(depth: depth - 1)
        )
    }
}
