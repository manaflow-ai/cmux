/** Canonical public P-256 point used by both pairing and network confirmation. */
export const installPublicPoint = (jwk: JsonWebKey): string => {
  const coordinate = (text: string | undefined) => {
    if (!text || !/^[A-Za-z0-9_-]{43}$/.test(text)) throw new Error("invalid install point")
    const bytes = Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/") + "="), (c) => c.charCodeAt(0))
    const canonical = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    if (bytes.length !== 32 || canonical !== text) throw new Error("invalid install point")
    return bytes
  }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256") throw new Error("invalid install point")
  return btoa(String.fromCharCode(4, ...coordinate(jwk.x), ...coordinate(jwk.y)))
}
