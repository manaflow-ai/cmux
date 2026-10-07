import CmuxMobileWire
import Foundation

/// The one op path for both the link `rpc` channel and ops `HostDO`
/// forwards: policy, ledger, daemon, then a refresh so the reply's seq covers
/// the op's events.
public actor MobileOpExecutor {
    private let policy: MobileOpPolicy
    private let owner: WorkspaceStreamOwner
    private let daemon: any MobileDaemon
    private let ledger: MobileOpLedger
    private var nextTx: UInt64 = 0

    public init(policy: MobileOpPolicy, owner: WorkspaceStreamOwner, daemon: any MobileDaemon,
                ledger: MobileOpLedger = MobileOpLedger()) {
        self.policy = policy
        self.owner = owner
        self.daemon = daemon
        self.ledger = ledger
    }

    public func execute(_ op: OpFrame, principal: MobileDevicePrincipal) async -> MobileOpReply {
        let stream = owner.stream
        guard Self.validKey(op.idempotencyKey) else {
            return MobileOpReply(idempotencyKey: op.idempotencyKey, stream: stream, outcome: .reject(
                tx: "tx_invalid", MobileOpRejection(code: "validation.invalid",
                                                    message: "idempotency_key must be 8 to 128 of [A-Za-z0-9._:-]")),
                                 replayed: false)
        }
        nextTx += 1
        let tx = "mtx_\(owner.hostID)_\(nextTx)"
        let fingerprint = (try? JSONValue.object(["op": .string(op.op), "params": op.params]).canonicalData()) ?? Data()
        let policy = policy
        let owner = owner
        let daemon = daemon
        let context = MobileOpContext(install: principal.install, idempotencyKey: op.idempotencyKey)
        let (outcome, replayed) = await ledger.run(install: principal.install, key: op.idempotencyKey,
                                                   fingerprint: fingerprint) {
            let state: MobileWorkspaceState
            do {
                state = try await owner.currentState()
            } catch {
                return .reject(tx: tx, MobileOpRejection(code: "owner.unreachable", message: "the daemon is unreachable",
                                                         retryable: true))
            }
            let daemonOp: MobileDaemonOp
            switch policy.evaluate(op: op.op, params: op.params, state: state) {
            case .success(let allowed): daemonOp = allowed
            case .failure(let rejection): return .reject(tx: tx, rejection)
            }
            do {
                let result = try await daemon.perform(daemonOp, context: context)
                await owner.refresh()
                return .result(tx: tx, value: result.value, sequence: await owner.headSeq)
            } catch let error as MobileDaemonError {
                return .reject(tx: tx, MobileOpRejection(code: error.code, message: error.message, retryable: error.retryable))
            } catch {
                return .reject(tx: tx, MobileOpRejection(code: "owner.unreachable", message: "the daemon did not answer",
                                                         retryable: true))
            }
        }
        return MobileOpReply(idempotencyKey: op.idempotencyKey, stream: stream, outcome: outcome, replayed: replayed)
    }

    public func decided(install: String, keys: [String]) async -> [DecidedKey] {
        await ledger.decided(install: install, keys: keys)
    }

    static func validKey(_ key: String) -> Bool {
        (8...128).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
    }
}
