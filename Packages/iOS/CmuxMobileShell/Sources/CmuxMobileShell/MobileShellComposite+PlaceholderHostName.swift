import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport

extension MobileShellComposite {
    /// Placeholder Mac name used until `mobile.host.status` reports the real one.
    func placeholderHostName(
        for ticket: CmxAttachTicket,
        firstRoute: CmxAttachRoute
    ) -> String {
        if let name = ticket.macDisplayName, !name.isEmpty {
            return name
        }
        if !ticket.macDeviceID.isEmpty {
            return ticket.macDeviceID
        }
        if case let .hostPort(host, _) = firstRoute.endpoint {
            return host
        }
        return ""
    }
}
