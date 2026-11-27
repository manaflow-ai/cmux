import { DOMParser } from "@xmldom/xmldom"
import { ExclusiveCanonicalization } from "xml-crypto"
import { describe, expect, it } from "vitest"
import { excC14n } from "../src/c14n.ts"

/** Our exclusive canonicalization must agree byte for byte with xml-crypto's on tricky inputs. */
const cases: Array<[string, string, string?]> = [
  ["nested prefixes and an unused declaration", `<a:r xmlns:a="urn:a" xmlns:b="urn:b" xmlns:unused="urn:u"><a:x b:attr="1" z="2" a:y="3"/></a:r>`],
  ["escaping in text and attributes", `<r a="&quot;&lt;&amp;&#9;&#10;&#13;">t &amp; &lt; &gt; &#13;</r>`],
  ["comments dropped", `<r><!-- c --><x>1<!--split-->2</x></r>`],
  ["subtree inherits ancestors' declarations", `<o xmlns:s="urn:s" xmlns="urn:d"><s:r s:a="1"><k/></s:r></o>`, "r"],
  ["attribute sort by namespace then local name", `<r xmlns:b="urn:b" xmlns:a="urn:a" b:z="1" a:z="2" y="3" a:a="4"/>`]
]

describe("exclusive c14n agrees with xml-crypto", () => {
  for (const [name, xml, apexName] of cases) {
    it(name, () => {
      const doc = new DOMParser().parseFromString(xml, "text/xml")
      const apex = apexName ? (Array.from(doc.getElementsByTagName("*")).find((e) => e.localName === apexName) as never) : (doc.documentElement as never)
      const theirs = new ExclusiveCanonicalization().process(apex, {}) as unknown as string
      expect(excC14n(apex)).toBe(theirs)
    })
  }
})

/**
 * Where xml-crypto departs from the W3C texts, the spec wins (IdPs sign with
 * xmlsec, .NET or Java, which follow it). Expected outputs from the spec:
 */
describe("exclusive c14n follows the W3C spec where xml-crypto does not", () => {
  const canon = (xml: string, apexName?: string, inclusivePrefixes?: Array<string>) => {
    const doc = new DOMParser().parseFromString(xml, "text/xml")
    const apex = apexName ? (doc.getElementsByTagName(apexName)[0] as never) : (doc.documentElement as never)
    return excC14n(apex, inclusivePrefixes ? { inclusivePrefixes } : {})
  }
  it('xmlns="" only where the nearest output ancestor rendered a non-empty default (exc-c14n 3, c14n 2.3)', () => {
    expect(canon(`<r xmlns="urn:d"><x><y xmlns=""><z/></y></x></r>`)).toBe(`<r xmlns="urn:d"><x><y xmlns=""><z></z></y></x></r>`)
  })
  it("processing instructions keep their syntax (c14n 2.3)", () => {
    expect(canon(`<r><?pi data?><x/></r>`)).toBe(`<r><?pi data?><x></x></r>`)
  })
  it("InclusiveNamespaces prefixes in scope are rendered, also when inherited (exc-c14n 3)", () => {
    expect(canon(`<o xmlns:p="urn:p" xmlns:q="urn:q"><r/></o>`, "r", ["p"])).toBe(`<r xmlns:p="urn:p"></r>`)
  })
})
