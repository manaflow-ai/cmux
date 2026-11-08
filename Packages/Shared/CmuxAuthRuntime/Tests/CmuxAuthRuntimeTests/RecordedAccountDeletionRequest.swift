import Foundation

actor RecordedAccountDeletionRequest {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}
