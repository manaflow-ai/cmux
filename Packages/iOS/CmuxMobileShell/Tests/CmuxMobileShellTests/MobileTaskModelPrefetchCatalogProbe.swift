import Foundation

actor MobileTaskModelPrefetchCatalogProbe {
    let data: Data
    private(set) var requestCount = 0

    init(data: Data) {
        self.data = data
    }

    func load() -> Data {
        requestCount += 1
        return data
    }
}
