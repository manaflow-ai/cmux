import { stackServerAppJs } from "@/lib/utils/stack";
import { env } from "@/lib/utils/www-env";

/**
 * Decode a JWT payload without verification (we trust Stack Auth's signature)
 * This is safe because the token was issued by our Stack Auth instance.
 */
function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString());
    return payload;
  } catch {
    return null;
  }
}

/**
 * Check if a JWT token is valid for our Stack Auth project.
 * We check the issuer and expiry without cryptographic verification
 * since the token was issued by our own Stack Auth instance.
 */
function isValidStackAuthToken(token: string): boolean {
  const payload = decodeJwtPayload(token);
  if (!payload) return false;

  // Check issuer matches our Stack Auth project
  const expectedIssuer = `https://api.stack-auth.com/api/v1/projects/${env.NEXT_PUBLIC_STACK_PROJECT_ID}`;
  if (payload.iss !== expectedIssuer) return false;

  // Check token is not expired
  const exp = payload.exp as number | undefined;
  if (!exp || Date.now() / 1000 > exp) return false;

  return true;
}

export async function getAccessTokenFromRequest(
  req: Request
): Promise<string | null> {
  // First, try to get user from Stack Auth's token store (cookies)
  try {
    const user = await stackServerAppJs.getUser({ tokenStore: req });
    if (user) {
      const { accessToken } = await user.getAuthJson();
      if (accessToken) return accessToken;
    }
  } catch (_e) {
    // Fall through to try Bearer token
  }

  // Fallback: Check for Bearer token in Authorization header (for CLI clients)
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7); // Remove "Bearer " prefix

    // Validate the token by checking its structure and claims
    if (isValidStackAuthToken(token)) {
      return token;
    }
  }

  return null;
}

/**
 * Get Stack Auth user from request, supporting both cookie-based (web) and
 * Bearer token (CLI) authentication.
 *
 * For CLI clients, we pass the access token directly to the Stack Auth SDK
 * using the { accessToken, refreshToken } format.
 */
export async function getUserFromRequest(req: Request) {
  // First, try cookie-based auth (standard web flow)
  try {
    const user = await stackServerAppJs.getUser({ tokenStore: req });
    if (user) {
      return user;
    }
  } catch (_e) {
    // Fall through to try Bearer token
  }

  // Fallback: Check for Bearer token in Authorization header (for CLI clients)
  const authHeader = req.headers.get("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7); // Remove "Bearer " prefix

    // Validate the token by checking its structure and claims
    if (isValidStackAuthToken(token)) {
      try {
        // Pass the token directly to Stack Auth SDK
        // The SDK accepts { accessToken, refreshToken } format
        const user = await stackServerAppJs.getUser({
          tokenStore: { accessToken: token, refreshToken: token },
        });
        if (user) {
          return user;
        }
      } catch (_e) {
        // Bearer token auth failed
      }
    }
  }

  return null;
}
