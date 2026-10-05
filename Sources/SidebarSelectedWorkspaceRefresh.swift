import Combine
import Foundation

enum SidebarSelectedWorkspaceRefresh {
    /// Refresh after native willSet publication has committed its selection.
    /// Keep the publisher's legacy timing unchanged for its other consumers.
    static func events(from publisher: CurrentValueSubject<UUID?, Never>) -> AnyPublisher<Void, Never> {
        publisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
