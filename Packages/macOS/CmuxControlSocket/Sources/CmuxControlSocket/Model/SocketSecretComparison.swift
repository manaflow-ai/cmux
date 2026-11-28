import Foundation

/// Compares fixed-size secret digests without returning early on a differing byte.
@inline(never)
func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }

    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}

func constantTimeEqual(_ lhs: Data?, _ rhs: Data?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (.some(left), .some(right)):
        return constantTimeEqual(left, right)
    default:
        return false
    }
}
