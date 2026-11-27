/// The three private restoration keys do not participate in settings observation.
protocol CloudTreeExpansionPersistence {
    func stringArray(forKey key: String) -> [String]?
    @discardableResult func setIfChanged(_ value: [String], forKey key: String) -> Bool
}
