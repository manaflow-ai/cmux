// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// Reads `PeerFacts` for a connected Unix socket from the kernel.
public protocol PeerInspecting: Sendable {
    func facts(forConnection descriptor: Int32, requirement: String?) -> PeerFacts?
}

/// The kernel-backed inspector: LOCAL_PEERCRED (uid), LOCAL_PEERTOKEN (audit
/// token, so the code check names this exact process instance), the Security
/// framework (signature validity, cdhash, requirement), and proc_pidinfo
/// (parent chain with start times).
public struct KernelPeerInspector: PeerInspecting {
    public init() {}

    public func facts(forConnection descriptor: Int32, requirement: String?) -> PeerFacts? {
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else { return nil }
        // audit_token_t: val[5] is the pid (audit_token_to_pid in libbsm).
        let pid = pid_t(bitPattern: token.val.5)
        guard let stamp = Self.stamp(pid) else { return nil }
        let code = Self.codeCheck(token: token, requirement: requirement)
        return PeerFacts(uid: credentials.cr_uid, stamp: stamp, signatureValid: code.valid,
                         cdhash: code.cdhash, satisfiesRequirement: code.satisfies,
                         ancestors: Self.ancestors(of: pid))
    }

    /// pid + start time of a live process, or nil.
    public static func stamp(_ pid: pid_t) -> ProcessStamp? {
        bsdInfo(pid).map {
            ProcessStamp(pid: pid, startSeconds: $0.pbi_start_tvsec, startMicroseconds: $0.pbi_start_tvusec)
        }
    }

    /// The parent chain of `pid`, nearest first, stopping before launchd (pid 1).
    public static func ancestors(of pid: pid_t, limit: Int = 64) -> [ProcessStamp] {
        var chain: [ProcessStamp] = []
        var current = pid
        for _ in 0..<limit {
            guard let info = bsdInfo(current) else { break }
            let parent = pid_t(info.pbi_ppid)
            guard parent > 1, let stamp = stamp(parent) else { break }
            // A parent that started after its child is a reused pid: stop.
            if stamp.startSeconds > info.pbi_start_tvsec
                || (stamp.startSeconds == info.pbi_start_tvsec && stamp.startMicroseconds > info.pbi_start_tvusec) { break }
            chain.append(stamp)
            current = parent
        }
        return chain
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func codeCheck(token: audit_token_t, requirement: String?) -> (valid: Bool, cdhash: Data?, satisfies: Bool) {
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return (false, nil, false)
        }
        guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return (false, nil, false) }
        var info: CFDictionary?
        var cdhash: Data?
        if SecCodeCopySigningInformation(unsafeBitCast(guest, to: SecStaticCode.self),
                                         SecCSFlags(rawValue: kSecCSDynamicInformation), &info) == errSecSuccess,
           let dictionary = info as? [String: Any] {
            cdhash = dictionary[kSecCodeInfoUnique as String] as? Data
        }
        var satisfies = false
        if let requirement {
            var compiled: SecRequirement?
            if SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled {
                satisfies = SecCodeCheckValidity(guest, [], compiled) == errSecSuccess
            }
        }
        return (true, cdhash, satisfies)
    }
}
