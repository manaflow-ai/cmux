import Testing
@testable import CmuxSidebarScript

@Suite struct SidebarScriptTests {
    private func sampleContext() -> SidebarScriptContext {
        SidebarScriptContext(
            title: "issue-118-korean-ime",
            detail: "Fix Korean IME composition",
            branch: "issue-118-korean-ime",
            directory: "~/cmux/worktrees/issue-118",
            pullRequests: [
                .init(number: 5108, state: "open", url: "https://github.com/manaflow-ai/cmux/pull/5108"),
                .init(number: 5099, state: "merged", url: "https://github.com/x/y/pull/5099", isStale: true),
            ],
            ports: [3000, 5173],
            unreadCount: 3,
            isPinned: true,
            isActive: true,
            progress: 0.4
        )
    }

    @Test func defaultScriptCompiles() throws {
        _ = try SidebarScript.makeDefault()
    }

    @Test func bundledDemoScriptsCompileAndRender() throws {
        let demos = SidebarScriptDemo.all
        #expect(demos.count >= 6)

        for demo in demos {
            do {
                let script = try SidebarScript(source: demo.source)
                let node = try script.render(sampleContext())
                #expect(node != .empty)
                #expect(node.containsText("issue-118-korean-ime") || node.containsText("ISSUE-118-KOREAN-IME"))
            } catch {
                Issue.record("Demo '\(demo.id)' failed: \(error)")
            }
        }
    }

    @Test func defaultScriptRendersRichRow() throws {
        let script = try SidebarScript.makeDefault()
        let node = try script.render(sampleContext())

        // Title is present.
        #expect(node.containsText("issue-118-korean-ime"))
        // Unread badge.
        #expect(node.containsText("3"))
        // Branch line exists.
        #expect(node.firstNode(kind: "image") != nil)
        // Both PR numbers rendered.
        #expect(node.containsText("#5108"))
        #expect(node.containsText("#5099"))
        // Ports rendered.
        #expect(node.containsText("3000"))
        #expect(node.containsText("5173"))
        // Progress bar present.
        #expect(node.firstNode(kind: "progress-view") != nil)
    }

    @Test func minimalContextHidesOptionalRows() throws {
        let script = try SidebarScript.makeDefault()
        let node = try script.render(SidebarScriptContext(title: "scratch"))
        #expect(node.containsText("scratch"))
        // No PRs, ports, or progress.
        #expect(node.nodes(kind: "progress-view").isEmpty)
        #expect(!node.containsText("#"))
    }

    @Test func customScriptOverridesRendering() throws {
        let script = try SidebarScript(source: """
        (def (render-row ws)
          (text (upper (get ws :title)) :font (font :size 20)))
        """)
        let node = try script.render(SidebarScriptContext(title: "hello"))
        #expect(node.containsText("HELLO"))
    }

    @Test func contextProjectsPullRequestFields() throws {
        let script = try SidebarScript(source: """
        (def (render-row ws)
          (text (get (first (get ws :pull-requests)) :state)))
        """)
        let node = try script.render(sampleContext())
        #expect(node.containsText("open"))
    }

    @Test func missingEntryPointThrows() {
        #expect(throws: LispError.self) {
            _ = try SidebarScript(source: "(def x 1)")
        }
    }

    @Test func entryReturningNonViewThrows() throws {
        let script = try SidebarScript(source: "(def (render-row ws) 42)")
        #expect(throws: LispError.self) {
            _ = try script.render(SidebarScriptContext(title: "x"))
        }
    }

    @Test func equalContextsProduceEqualNodes() throws {
        // Underpins per-row memoization: same input → identical (Equatable) node.
        let script = try SidebarScript.makeDefault()
        let a = try script.render(sampleContext())
        let b = try script.render(sampleContext())
        #expect(a == b)
    }

    @Test func renderCannotMutateTopLevelBindings() throws {
        let script = try SidebarScript(source: """
        (def counter 0)
        (def (render-row ws)
          (do
            (set! counter (+ counter 1))
            (text (str counter))))
        """)
        #expect(throws: LispError.self) {
            _ = try script.render(SidebarScriptContext(title: "x"))
        }
    }

    @Test func renderCanMutateLocalBindings() throws {
        let script = try SidebarScript(source: """
        (def (render-row ws)
          (let ((value 1))
            (set! value 2)
            (text (str value))))
        """)
        let node = try script.render(SidebarScriptContext(title: "x"))
        #expect(node.containsText("2"))
    }
}
