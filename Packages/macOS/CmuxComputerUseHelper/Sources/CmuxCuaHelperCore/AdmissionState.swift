// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// The current admission config; the control pipe writes it, the socket reads it.
public final class AdmissionState: Sendable {
    private let config = OSAllocatedUnfairLock<AdmissionConfig?>(initialState: nil)
    public init() {}

    public var current: AdmissionConfig? { config.withLockUnchecked { $0 } }

    public func configure(_ value: AdmissionConfig) { config.withLockUnchecked { $0 = value } }

    /// Registers an acpmux daemon the host found. False before `configure`.
    @discardableResult
    public func register(daemon: ProcessStamp) -> Bool {
        config.withLockUnchecked { state in
            guard state != nil else { return false }
            state?.acpmuxDaemons.insert(daemon)
            return true
        }
    }
}
