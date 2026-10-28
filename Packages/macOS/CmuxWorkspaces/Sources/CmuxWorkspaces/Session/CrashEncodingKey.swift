/// A path component used by the bounded snapshot counting encoder.
struct CrashEncodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(index: Int) { stringValue = "Index \(index)"; intValue = index }
    init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init(intValue: Int) { self.init(index: intValue) }
}
