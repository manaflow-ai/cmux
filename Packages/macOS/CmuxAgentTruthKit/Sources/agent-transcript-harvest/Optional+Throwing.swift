import Foundation

extension Optional {
    func orThrow(_ error: any Error) throws -> Wrapped {
        guard let self else {
            throw error
        }
        return self
    }
}
