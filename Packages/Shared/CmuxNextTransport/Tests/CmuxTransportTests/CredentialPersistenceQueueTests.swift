import CmuxNextTransport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CredentialPersistenceQueueTests {
    @Test @MainActor
    func deletionFollowsWriteWhileOtherIdentitiesRemainIndependent() async {
        let queue = CredentialPersistenceQueue()
        let recorder = CredentialPersistenceRecorder()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = queue.enqueue(key: "mac") {
            started.continuation.yield(())
            var gate = release.stream.makeAsyncIterator()
            _ = await gate.next()
            await recorder.record("write")
            return true
        }
        var readiness = started.stream.makeAsyncIterator()
        _ = await readiness.next()
        let deletion = queue.enqueue(key: "mac") {
            await recorder.record("delete")
            return true
        }
        let independent = queue.enqueue(key: "other-mac") { true }
        #expect(await independent.value)
        #expect(queue.hasPending(key: "mac"))
        #expect(!queue.permitsRead(key: "mac"))
        #expect(queue.permitsRead(key: "other-mac"))
        release.continuation.finish()
        #expect(await first.value)
        #expect(await deletion.value)
        #expect(await recorder.snapshot() == ["write", "delete"])
        #expect(!queue.hasPending(key: "mac"))
        #expect(queue.permitsRead(key: "mac"))
        started.continuation.finish()
    }

    @Test @MainActor
    func failedMutationRefusesStaleStorageUntilASuccessfulMutation() async {
        let queue = CredentialPersistenceQueue()
        let failed = queue.enqueue(key: "mac") { false }
        #expect(!(await failed.value))
        #expect(!queue.hasPending(key: "mac"))
        #expect(!queue.permitsRead(key: "mac"))
        #expect(queue.permitsRead(key: "other-mac"))
        let retry = queue.enqueue(key: "mac") { true }
        #expect(await retry.value)
        #expect(queue.permitsRead(key: "mac"))
    }

    @Test @MainActor
    func cancellingTheResultTaskDoesNotDropAnAcceptedMutation() async {
        let queue = CredentialPersistenceQueue()
        let recorder = CredentialPersistenceRecorder()
        let write = queue.enqueue(key: "mac") {
            await recorder.record("write")
            return true
        }
        write.cancel()
        #expect(await write.value)
        #expect(await recorder.snapshot() == ["write"])
        #expect(queue.permitsRead(key: "mac"))
    }
}
