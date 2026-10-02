/**
 * Exclusive XML Canonicalization 1.0 without comments
 * (https://www.w3.org/TR/xml-exc-c14n/), over a DOM subtree, the only
 * canonicalization this SAML validator accepts. Written for the subset SAML
 * needs; no DTD (documents with a DOCTYPE are refused before parsing).
 *
 * - Namespace declarations are rendered on an element only when it visibly
 *   uses them (its own prefix or an attribute's) or they are in the
 *   InclusiveNamespaces PrefixList, and only when an output ancestor has not
 *   already rendered the same value.
 * - Namespace declarations sort by prefix (default first); attributes sort by
 *   namespace URI, then local name.
 * - Comments are dropped; processing instructions are kept.
 */
const XMLNS = "http://www.w3.org/2000/xmlns/"
const ELEMENT = 1
const TEXT = 3
const CDATA = 4
const PI = 7

type DomNode = { nodeType: number; childNodes: ArrayLike<DomNode>; parentNode: DomNode | null }
type DomAttr = { name: string; prefix: string | null; localName: string; namespaceURI: string | null; value: string }
type DomElement = DomNode & { tagName: string; prefix: string | null; localName: string; namespaceURI: string | null; attributes: ArrayLike<DomAttr> }
type DomCharacterData = DomNode & { data: string }
type DomPI = DomNode & { target: string; data: string }

const escapeText = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\r/g, "&#xD;")
const escapeAttr = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;").replace(/\t/g, "&#x9;").replace(/\n/g, "&#xA;").replace(/\r/g, "&#xD;")

/** This element's own namespace declarations applied over `parent` (prefix "" is the default namespace). */
const withOwn = (el: DomElement, parent: Map<string, string>): Map<string, string> => {
  let map = parent
  for (const a of Array.from(el.attributes)) {
    if (a.namespaceURI !== XMLNS) continue
    if (map === parent) map = new Map(parent)
    map.set(a.prefix === "xmlns" ? a.localName : "", a.value)
  }
  return map
}

/** Namespace declarations in scope at `el` (nearest wins), computed once for the apex. */
const inScope = (el: DomElement): Map<string, string> => {
  const chain: Array<DomElement> = []
  for (let n: DomNode | null = el; n && n.nodeType === ELEMENT; n = n.parentNode) chain.push(n as DomElement)
  const map = new Map<string, string>()
  for (const e of chain.reverse()) {
    for (const a of Array.from(e.attributes)) {
      if (a.namespaceURI !== XMLNS) continue
      map.set(a.prefix === "xmlns" ? a.localName : "", a.value)
    }
  }
  return map
}

const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0)

/**
 * Canonical form of `apex` and its descendants. `skip` (the enveloped
 * Signature) is left out with its subtree. `inclusivePrefixes` comes from the
 * transform's InclusiveNamespaces PrefixList ("#default" is the default namespace).
 */
export const excC14n = (apex: DomElement, options: { skip?: DomNode; inclusivePrefixes?: ReadonlyArray<string> } = {}): string => {
  const inclusive = new Set((options.inclusivePrefixes ?? []).map((p) => (p === "#default" ? "" : p)))
  const out: Array<string> = []

  // The scope is passed down the tree (linear in the subtree), not recomputed per element from its ancestors.
  const element = (el: DomElement, rendered: Map<string, string>, scope: Map<string, string>) => {
    const used = new Set<string>([el.prefix ?? ""])
    const attrs: Array<DomAttr> = []
    for (const a of Array.from(el.attributes)) {
      if (a.namespaceURI === XMLNS) continue
      attrs.push(a)
      if (a.prefix && a.prefix !== "xml") used.add(a.prefix)
    }
    for (const p of inclusive) if (scope.has(p)) used.add(p)

    const next = new Map(rendered)
    const decls: Array<[string, string]> = []
    for (const p of [...used].sort(cmp)) {
      const uri = scope.get(p) ?? ""
      if (p === "") {
        const prev = rendered.get("") ?? ""
        if (uri === prev) continue
        decls.push(["", uri])
        next.set("", uri)
      } else {
        if (!scope.has(p)) throw new Error(`c14n: prefix ${p} is not declared`)
        if (rendered.get(p) === uri) continue
        decls.push([p, uri])
        next.set(p, uri)
      }
    }
    attrs.sort((x, y) => cmp(x.namespaceURI ?? "", y.namespaceURI ?? "") || cmp(x.localName, y.localName))

    out.push(`<${el.tagName}`)
    for (const [p, uri] of decls) out.push(p === "" ? ` xmlns="${escapeAttr(uri)}"` : ` xmlns:${p}="${escapeAttr(uri)}"`)
    for (const a of attrs) out.push(` ${a.name}="${escapeAttr(a.value)}"`)
    out.push(">")
    for (const child of Array.from(el.childNodes)) node(child, next, scope)
    out.push(`</${el.tagName}>`)
  }

  const node = (n: DomNode, rendered: Map<string, string>, parentScope: Map<string, string>) => {
    if (n === options.skip) return
    switch (n.nodeType) {
      case ELEMENT:
        return element(n as DomElement, rendered, withOwn(n as DomElement, parentScope))
      case TEXT:
      case CDATA:
        return void out.push(escapeText((n as DomCharacterData).data))
      case PI: {
        const pi = n as DomPI
        return void out.push(pi.data ? `<?${pi.target} ${pi.data}?>` : `<?${pi.target}?>`)
      }
      default:
        // Comments (8) and anything else are not part of the canonical form.
        return
    }
  }

  element(apex, new Map(), inScope(apex))
  return out.join("")
}
