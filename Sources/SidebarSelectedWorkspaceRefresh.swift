import Combine
import Foundation

enum SidebarSelectedWorkspaceRefresh {
    /// Emits once per actual selection change, ignoring the subject's initial value.
    static func events(from publisher: CurrentValueSubject<UUID?, Never>) -> AnyPublisher<Void, Never> {
        publisher
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
