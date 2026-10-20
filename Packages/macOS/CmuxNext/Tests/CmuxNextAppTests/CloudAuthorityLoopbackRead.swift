import Foundation
@testable import CmuxNextCloud

/// An owned real URLSession receive; deadline failure closes and joins it even if its cancellation handler regresses.
actor CloudAuthorityLoopbackRead {
    private let socket: any CloudAuthorityWireSocket
    private let running: Task<Void, Never>
    private let results: AsyncStream<Result<Data, any Error>>

    init(_ socket: any CloudAuthorityWireSocket) {
        self.socket = socket
        let result = AsyncStream<Result<Data, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = result.stream
        // task-owner: running; result joins completion or closes the socket and joins on timeout.
        running = Task {
            do { result.continuation.yield(.success(try await socket.receive())) }
            catch { result.continuation.yield(.failure(error)) }
            result.continuation.finish()
        }
    }

    func cancel() { running.cancel() }

    func result() async throws -> Result<Data, any Error> {
        let results = results
        do {
            let result = try await withDeadline(.seconds(5), label: "real owner socket receive") {
                var iterator = results.makeAsyncIterator()
                guard let result = await iterator.next() else { throw CancellationError() }
                return result
            }
            await running.value
            return result
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        running.cancel()
        await socket.close()
        await running.value
    }
}
