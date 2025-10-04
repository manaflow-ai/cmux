import { describe, expect, it } from "vitest";
import {
  ensureStackAuthTokensFresh,
  StackAuthError,
} from "./stackTokens";

function createJwt(expSecondsFromNow: number): string {
  const header = Buffer.from(
    JSON.stringify({ alg: "none", typ: "JWT" })
  ).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({
      exp: Math.floor(Date.now() / 1000) + expSecondsFromNow,
      sub: "test-user",
    })
  ).toString("base64url");
  return `${header}.${payload}.`;
}

describe("ensureStackAuthTokensFresh", () => {
  it("returns existing token when it is not expiring", async () => {
    const token = createJwt(3600);
    const authJson = JSON.stringify({ accessToken: token, refreshToken: "refresh" });

    const result = await ensureStackAuthTokensFresh({ authJson });

    expect(result.accessToken).toBe(token);
    expect(result.updated).toBe(false);
    expect(result.authJson).toBe(authJson);
  });

  it("refreshes the access token when it is expiring soon", async () => {
    const expiringToken = createJwt(10);
    const refreshedToken = createJwt(3600);
    const authJson = JSON.stringify({
      accessToken: expiringToken,
      refreshToken: "refresh-token",
    });

    const result = await ensureStackAuthTokensFresh({
      authJson,
      refreshAccessToken: async (refreshToken) => {
        expect(refreshToken).toBe("refresh-token");
        return refreshedToken;
      },
      refreshBufferSeconds: 30,
    });

    expect(result.accessToken).toBe(refreshedToken);
    expect(result.updated).toBe(true);
    expect(JSON.parse(result.authJson)).toEqual({
      accessToken: refreshedToken,
      refreshToken: "refresh-token",
    });
  });

  it("throws when refresh token is missing for an expiring access token", async () => {
    const expiringToken = createJwt(5);
    const authJson = JSON.stringify({ accessToken: expiringToken });

    await expect(
      ensureStackAuthTokensFresh({
        authJson,
        refreshBufferSeconds: 30,
      })
    ).rejects.toBeInstanceOf(StackAuthError);
  });

  it("throws when auth JSON is missing", async () => {
    await expect(
      ensureStackAuthTokensFresh({ authJson: undefined })
    ).rejects.toBeInstanceOf(StackAuthError);
  });
});
