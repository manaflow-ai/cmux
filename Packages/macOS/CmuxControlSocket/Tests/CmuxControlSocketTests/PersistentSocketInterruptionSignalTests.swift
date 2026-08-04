import Darwin
import Dispatch
import Testing

@testable import CmuxControlSocket

@Suite(.serialized) struct PersistentSocketInterruptionSignalTests {
    @Test func aDelayedInterruptCannotReachTheNextGeneration() throws {
        let first = try UnixSocketFixture.makeSocketPair()
        let second = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(first.reader)
            Darwin.close(first.writer)
            Darwin.close(second.reader)
            Darwin.close(second.writer)
        }
        let interruptClaimed = DispatchSemaphore(value: 0)
        let allowInterrupt = DispatchSemaphore(value: 0)
        let interruptCompleted = DispatchSemaphore(value: 0)
        let signal = PersistentSocketInterruptionSignal(
            interruptSocket: { socket in
                interruptClaimed.signal()
                _ = allowInterrupt.wait(timeout: .now() + 2)
                Darwin.shutdown(socket, SHUT_RDWR)
                Darwin.close(socket)
                interruptCompleted.signal()
            }
        )
        let firstGeneration = signal.begin()
        #expect(signal.install(
            socket: first.writer,
            generation: firstGeneration
        ))

        DispatchQueue.global(qos: .userInitiated).async {
            signal.trigger(generation: firstGeneration)
        }
        #expect(interruptClaimed.wait(timeout: .now() + 1) == .success)
        #expect(signal.retire(generation: firstGeneration))

        let secondGeneration = signal.begin()
        #expect(signal.install(
            socket: second.writer,
            generation: secondGeneration
        ))
        allowInterrupt.signal()
        #expect(interruptCompleted.wait(timeout: .now() + 1) == .success)

        #expect(!signal.isTriggered(generation: secondGeneration))
        #expect(!signal.retire(generation: secondGeneration))
    }

    @Test func interruptionDuplicatesAreCloseOnExecFromCreation() throws {
        let sockets = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }
        let signal = PersistentSocketInterruptionSignal(
            interruptSocket: { socket in
                let flags = Darwin.fcntl(socket, F_GETFD, 0)
                #expect(flags >= 0)
                #expect(flags & FD_CLOEXEC != 0)
                Darwin.close(socket)
            }
        )
        let generation = signal.begin()
        #expect(signal.install(
            socket: sockets.writer,
            generation: generation
        ))

        signal.trigger(generation: generation)

        #expect(signal.retire(generation: generation))
    }

    @Test func republishingWithinAGenerationInterruptsTheNewestSocket() throws {
        let first = try UnixSocketFixture.makeSocketPair()
        let second = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(first.reader)
            Darwin.close(first.writer)
            Darwin.close(second.reader)
            Darwin.close(second.writer)
        }
        #expect(Darwin.fcntl(first.reader, F_SETFL, O_NONBLOCK) == 0)
        #expect(Darwin.fcntl(second.reader, F_SETFL, O_NONBLOCK) == 0)

        let signal = PersistentSocketInterruptionSignal()
        let generation = signal.begin()
        #expect(signal.install(socket: first.writer, generation: generation))
        #expect(signal.install(socket: second.writer, generation: generation))

        signal.trigger(generation: generation)

        var byte: UInt8 = 0
        #expect(Darwin.read(second.reader, &byte, 1) == 0)
        #expect(Darwin.read(first.reader, &byte, 1) == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        #expect(signal.retire(generation: generation))
    }
}
