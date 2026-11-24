import Testing
@testable import CmuxFoundation

/// The Eternal Terminal login-shell line: how it is rendered and what fits its byte budget.
@Suite("Remote tmux Eternal Terminal command line")
struct RemoteTmuxETCommandLineTests {
    private func attach(_ session: String, socketName: String? = nil) -> RemoteTmuxETCommandLine {
        RemoteTmuxETCommandLine(
            tmuxArguments: ["-CC", "attach-session", "-t", session], socketName: socketName)
    }

    /// The budget is the canonical line minus the transport's allowance.
    @Test func theBudgetIsTheLineMinusTheTransportAllowance() {
        #expect(RemoteTmuxETCommandLine.maxCanonicalLineBytes == 1024)
        #expect(RemoteTmuxETCommandLine.deliverableCommandBytes == 1024 - 96)
    }

    /// Every word is single-quoted, and the default server adds nothing.
    @Test func rendersEveryWordSingleQuoted() {
        #expect(attach("work").rendered == "'tmux' '-CC' 'attach-session' '-t' 'work'")
    }

    /// A socket name puts `-L <name>` between `tmux` and the arguments.
    @Test func aSocketNameSelectsTheServerBeforeTheArguments() {
        #expect(attach("work", socketName: "alpha").rendered
            == "'tmux' '-L' 'alpha' '-CC' 'attach-session' '-t' 'work'")
    }

    /// An embedded single quote is closed, escaped and reopened, which costs three extra bytes.
    @Test func anEmbeddedQuoteIsEscapedAndCostsThreeBytes() {
        #expect(attach("it's").rendered == "'tmux' '-CC' 'attach-session' '-t' 'it'\\''s'")
        #expect(attach("it's").rendered.utf8.count == attach("itXs").rendered.utf8.count + 3)
    }

    /// A line of exactly the budget fits; one byte more is an overrun that reports both sizes.
    @Test func aLineOfExactlyTheBudgetFitsAndOneByteMoreDoesNot() {
        let budget = RemoteTmuxETCommandLine.deliverableCommandBytes
        let room = budget - attach("").rendered.utf8.count
        let exact = attach(String(repeating: "n", count: room))
        let over = attach(String(repeating: "n", count: room + 1))

        #expect(exact.rendered.utf8.count == budget)
        #expect(exact.overrun == nil)
        #expect(over.overrun?.actual == budget + 1)
        #expect(over.overrun?.budget == budget)
    }

    /// The socket name is spent from the same budget, so a session that fits the default
    /// server's line can overrun a named server's.
    @Test func theSocketNameIsSpentFromTheSameBudget() {
        let room = RemoteTmuxETCommandLine.deliverableCommandBytes - attach("").rendered.utf8.count
        let session = String(repeating: "n", count: room)

        #expect(attach(session).overrun == nil)
        #expect(attach(session, socketName: "alpha").overrun?.actual
            == RemoteTmuxETCommandLine.deliverableCommandBytes + "'-L' 'alpha' ".utf8.count)
    }

    /// A quote in the session name can push an otherwise fitting line over the budget.
    @Test func quotingCountsAgainstTheBudget() {
        let room = RemoteTmuxETCommandLine.deliverableCommandBytes - attach("").rendered.utf8.count
        let quoted = String(repeating: "n", count: room - 1) + "'"

        #expect(quoted.utf8.count == room)
        #expect(attach(quoted).overrun?.actual == RemoteTmuxETCommandLine.deliverableCommandBytes + 3)
    }
}
