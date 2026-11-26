import Foundation

actor ConnectCancellationBox {
    private var task: Task<Data, any Error>?

    func set(_ task: Task<Data, any Error>) {
        self.task = task
    }

    func cancelWhenSet() async {
        while task == nil {
            await Task.yield()
        }
        task?.cancel()
    }
}
