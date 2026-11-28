import { createHmac } from "node:crypto"
import { crockford } from "./base32.ts"

/**
 * Address addresses (home-messaging.md section 2). The normalized address is
 * the only form that is stored, compared or hashed. Plus addressing is kept:
 * for many providers `a+b@x` is a different mailbox.
 */
export type Channel = "email" | "sms"

export interface Address {
  readonly channel: Channel
  /** Lowercase email, or an E.164 phone number. */
  readonly value: string
}

export type NormalizeError = "address.invalid" | "address.country_not_allowed" | "address.not_mobile"

const EMAIL = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})+$/

export const normalizeEmail = (input: string): Address | NormalizeError => {
  const value = input.trim().toLowerCase()
  if (value.length > 254 || !EMAIL.test(value)) return "address.invalid"
  const [local, host] = value.split("@") as [string, string]
  if (local.startsWith(".") || local.endsWith(".") || local.includes("..")) return "address.invalid"
  if (host.split(".").some((label) => label.startsWith("-") || label.endsWith("-"))) return "address.invalid"
  return { channel: "email", value }
}

/**
 * Countries that text-message invites may reach, by calling code.
 * Launch: North America only (D-H5). `+1` is the North American Numbering
 * Plan; other calling codes are refused until a country is added here.
 */
export const SMS_COUNTRY_CODES: ReadonlyArray<string> = ["1"]

/** NANP area codes that are not mobile subscriber numbers (premium, toll free, service). */
const NANP_REFUSED_AREA = new Set(["800", "833", "844", "855", "866", "877", "888", "900", "976"])
/**
 * NANP area codes outside the US and Canada (Caribbean and Atlantic countries,
 * common in SMS pumping fraud). D-H5 allows only the US and Canada.
 */
const NANP_FOREIGN_AREA = new Set([
  "242", "246", "264", "268", "284", "345", "441", "473", "649", "658", "664", "721", "758", "767", "784", "809", "829", "849", "868", "869", "876"
])

/**
 * E.164 for a phone number typed by a user in `region` (only `US`/`CA`
 * defaults today). Accepts `+<digits>`, `00<digits>` and national numbers;
 * separators are ignored.
 */
export const normalizePhone = (input: string, region = "US"): Address | NormalizeError => {
  const trimmed = input.trim()
  if (!/^[+0-9 ().\-]{4,32}$/.test(trimmed)) return "address.invalid"
  const digits = trimmed.replace(/[^0-9]/g, "")
  let e164: string
  if (trimmed.startsWith("+")) e164 = digits
  else if (digits.startsWith("00")) e164 = digits.slice(2)
  else if ((region === "US" || region === "CA") && digits.length === 10) e164 = `1${digits}`
  else if ((region === "US" || region === "CA") && digits.length === 11 && digits.startsWith("1")) e164 = digits
  else return "address.invalid"
  if (e164.length < 8 || e164.length > 15 || e164.startsWith("0")) return "address.invalid"
  const code = SMS_COUNTRY_CODES.find((c) => e164.startsWith(c))
  if (!code) return "address.country_not_allowed"
  if (code === "1") {
    if (e164.length !== 11) return "address.invalid"
    const area = e164.slice(1, 4)
    const exchange = e164.slice(4, 7)
    // NANP: area and exchange never start with 0 or 1.
    if (/^[01]/.test(area) || /^[01]/.test(exchange)) return "address.invalid"
    if (NANP_REFUSED_AREA.has(area)) return "address.not_mobile"
    if (NANP_FOREIGN_AREA.has(area)) return "address.country_not_allowed"
  }
  return { channel: "sms", value: `+${e164}` }
}

/** An email if the input has an `@`, else a phone number. */
export const normalizeAddress = (input: string, region = "US"): Address | NormalizeError =>
  input.includes("@") ? normalizeEmail(input) : normalizePhone(input, region)

export const isAddress = (value: Address | NormalizeError): value is Address => typeof value !== "string"

/**
 * `addr_<26>`: HMAC-SHA256 with the per-environment secret
 * `HOME_ADDRESS_KEY`, so the id cannot be reversed by hashing guessed
 * addresses without the key.
 */
export const addressId = (key: string, address: Address): string => {
  if (key.length < 32) throw new Error("HOME_ADDRESS_KEY must have at least 32 characters")
  const mac = createHmac("sha256", key).update(`${address.channel}\u0000${address.value}`).digest()
  return `addr_${crockford(mac, 26)}`
}

/** For other members' views and logs: `l***@example.com`, `+1 *** *** 0123`. */
export const maskAddress = (address: Address): string => {
  if (address.channel === "email") {
    const [local, host] = address.value.split("@") as [string, string]
    return `${local.slice(0, 1)}***@${host}`
  }
  return `+${address.value.slice(1, address.value.length - 10)} *** *** ${address.value.slice(-4)}`
}
