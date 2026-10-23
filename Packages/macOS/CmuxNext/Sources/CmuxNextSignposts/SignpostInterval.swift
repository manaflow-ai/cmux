public import os

/// An open interval returned by ``Signposter/begin(_:_:)``; end it exactly once.
public nonisolated struct SignpostInterval {
    let state: OSSignpostIntervalState
}
