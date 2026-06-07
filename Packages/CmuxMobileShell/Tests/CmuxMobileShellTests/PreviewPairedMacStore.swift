import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor PreviewPairedMacStore: MobilePairedMacStoring {
    private var mac: MobilePairedMac?

    init(activeMac: MobilePairedMac?) {
        self.mac = activeMac
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        mac = MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            createdAt: now,
            lastSeenAt: now,
            isActive: markActive,
            stackUserID: stackUserID
        )
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        mac.map { [$0] } ?? []
    }

    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        mac
    }

    func setActive(macDeviceID: String) async throws {}

    func remove(macDeviceID: String) async throws {
        if mac?.macDeviceID == macDeviceID {
            mac = nil
        }
    }

    func removeAll() async throws {
        mac = nil
    }
}

actor SuspendedActiveMacStore: MobilePairedMacStoring {
    private let mac: MobilePairedMac
    private var didReceiveActiveMacRequest = false
    private var activeMacRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(activeMac: MobilePairedMac) {
        self.mac = activeMac
    }

    func waitForActiveMacRequest() async {
        if didReceiveActiveMacRequest {
            return
        }
        await withCheckedContinuation { continuation in
            activeMacRequestWaiters.append(continuation)
        }
    }

    func releaseActiveMac() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func upsert(
        macDeviceID _: String,
        displayName _: String?,
        routes _: [CmxAttachRoute],
        markActive _: Bool,
        stackUserID _: String?,
        now _: Date
    ) async throws {}

    func loadAll(stackUserID _: String?) async throws -> [MobilePairedMac] {
        [mac]
    }

    func activeMac(stackUserID _: String?) async throws -> MobilePairedMac? {
        didReceiveActiveMacRequest = true
        activeMacRequestWaiters.forEach { $0.resume() }
        activeMacRequestWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return mac
    }

    func setActive(macDeviceID _: String) async throws {}

    func remove(macDeviceID _: String) async throws {}

    func removeAll() async throws {}
}
