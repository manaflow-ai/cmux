import CMUXMobileCore

struct MobileShellRoutedConnectionError: Error {
    let underlying: any Error
    let route: CmxAttachRoute
}
