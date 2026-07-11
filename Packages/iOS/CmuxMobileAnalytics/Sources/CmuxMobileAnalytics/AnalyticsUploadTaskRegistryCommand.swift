internal import Foundation

enum AnalyticsUploadTaskRegistryCommand: Sendable {
    case register(Task<AnalyticsUploadResult, Never>, UUID, CheckedContinuation<Bool, Never>)
    case remove(UUID)
    case setEnabled(Bool)
}
