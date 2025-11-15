import { createHash, randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import tls, { type SecureContext } from "node:tls";
import type forgeType from "node-forge";

const nodeRequire = createRequire(import.meta.url);
const forge = nodeRequire("node-forge") as typeof forgeType;

export interface PreviewProxyCertificateAuthority {
  readonly certificatePem: string;
  readonly subject: string;
  readonly fingerprint256: string;
}

const CA_COMMON_NAME = "Cmux Preview Proxy CA";
const SERVER_ORG = "Cmux Preview Proxy";

type KeyPair = forgeType.pki.rsa.KeyPair;

let caKeyPair: KeyPair | null = null;
let caCertificate: forgeType.pki.Certificate | null = null;
let caCertificatePem: string | null = null;
let caFingerprint256: string | null = null;

const secureContextCache = new Map<string, SecureContext>();

function ensureCertificateAuthority(): void {
  if (caKeyPair && caCertificate && caCertificatePem && caFingerprint256) {
    return;
  }

  const keyPair = forge.pki.rsa.generateKeyPair({ bits: 2048 });
  const cert = forge.pki.createCertificate();
  cert.publicKey = keyPair.publicKey;
  cert.serialNumber = randomSerialNumber();
  cert.validity.notBefore = new Date();
  cert.validity.notBefore.setDate(cert.validity.notBefore.getDate() - 1);
  cert.validity.notAfter = new Date();
  cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 5);

  const attrs = [{ name: "commonName", value: CA_COMMON_NAME }];
  cert.setSubject(attrs);
  cert.setIssuer(attrs);
  cert.setExtensions([
    { name: "basicConstraints", cA: true },
    {
      name: "keyUsage",
      keyCertSign: true,
      digitalSignature: true,
      cRLSign: true,
    },
    {
      name: "subjectKeyIdentifier",
    },
    {
      name: "authorityKeyIdentifier",
      keyIdentifier: true,
    },
  ]);

  cert.sign(keyPair.privateKey, forge.md.sha256.create());

  const pem = forge.pki.certificateToPem(cert);
  const fingerprint = sha256FingerprintFromDer(
    Buffer.from(forge.asn1.toDer(forge.pki.certificateToAsn1(cert)).getBytes(), "binary")
  );

  caKeyPair = keyPair;
  caCertificate = cert;
  caCertificatePem = pem;
  caFingerprint256 = fingerprint;
}

function randomSerialNumber(): string {
  return Buffer.from(randomBytes(16)).toString("hex");
}

function sha256FingerprintFromDer(der: Buffer): string {
  return createHash("sha256").update(der).digest("hex").toUpperCase();
}

function ensureServerContext(hostname: string): SecureContext {
  ensureCertificateAuthority();
  if (!caKeyPair || !caCertificate || !caCertificatePem) {
    throw new Error("Failed to initialize preview proxy certificate authority");
  }
  const existing = secureContextCache.get(hostname);
  if (existing) {
    return existing;
  }

  const keyPair = forge.pki.rsa.generateKeyPair({ bits: 2048 });
  const cert = forge.pki.createCertificate();
  cert.publicKey = keyPair.publicKey;
  cert.serialNumber = randomSerialNumber();
  cert.validity.notBefore = new Date();
  cert.validity.notBefore.setDate(cert.validity.notBefore.getDate() - 1);
  cert.validity.notAfter = new Date();
  cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 1);

  const subject = [
    { name: "commonName", value: hostname },
    { name: "organizationName", value: SERVER_ORG },
  ];
  cert.setSubject(subject);
  cert.setIssuer(caCertificate.subject.attributes);
  const altNames = buildAltNames(hostname);
  cert.setExtensions([
    { name: "basicConstraints", cA: false },
    {
      name: "keyUsage",
      digitalSignature: true,
      keyEncipherment: true,
    },
    { name: "extKeyUsage", serverAuth: true },
    { name: "subjectAltName", altNames },
  ]);

  cert.sign(caKeyPair.privateKey, forge.md.sha256.create());

  const certPem = forge.pki.certificateToPem(cert);
  const keyPem = forge.pki.privateKeyToPem(keyPair.privateKey);
  const secureContext = tls.createSecureContext({
    key: keyPem,
    cert: `${certPem}${caCertificatePem}`,
  });
  secureContextCache.set(hostname, secureContext);
  return secureContext;
}

function buildAltNames(hostname: string): Array<{ type: number; value?: string; ip?: string }> {
  if (isIpAddress(hostname)) {
    return [{ type: 7, ip: hostname }];
  }
  return [{ type: 2, value: hostname }];
}

function isIpAddress(hostname: string): boolean {
  return (
    /^\d+\.\d+\.\d+\.\d+$/.test(hostname) ||
    /^[0-9a-fA-F:]+$/.test(hostname)
  );
}

export function getSecureContextForHostname(hostname: string): SecureContext {
  return ensureServerContext(hostname);
}

export function getPreviewProxyCertificateAuthority(): PreviewProxyCertificateAuthority {
  ensureCertificateAuthority();
  if (!caCertificatePem || !caFingerprint256) {
    throw new Error("Preview proxy certificate authority is not initialized");
  }
  return {
    certificatePem: caCertificatePem,
    subject: CA_COMMON_NAME,
    fingerprint256: caFingerprint256,
  };
}
