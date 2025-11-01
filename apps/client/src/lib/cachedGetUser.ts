import type { StackClientApp } from "@stackframe/react";
import { decodeJwt } from "jose";

type User = Awaited<ReturnType<StackClientApp["getUser"]>>;
declare global {
  interface Window {
    cachedUser: User | null;
    userPromise: Promise<User | null> | null;
  }
}

export function resetCachedUserCache() {
  if (typeof window === "undefined") return;
  window.cachedUser = null;
  window.userPromise = null;
}

export async function cachedGetUser(
  stackClientApp: StackClientApp
): Promise<User | null> {
  // If we have a cached user, check if it's still valid
  if (window.cachedUser) {
    try {
      const tokens = await window.cachedUser.currentSession.getTokens();
      if (!tokens.accessToken) {
        resetCachedUserCache();
        return null;
      }
      const jwt = decodeJwt(tokens.accessToken);
      if (jwt.exp && jwt.exp < Date.now() / 1000) {
        resetCachedUserCache();
        return null;
      }
      return window.cachedUser;
    } catch (error) {
      console.warn("Error checking cached user validity:", error);
      resetCachedUserCache();
    }
  }

  if (window.userPromise) {
    return window.userPromise;
  }

  window.userPromise = (async () => {
    try {
      const user = await stackClientApp.getUser();

      if (!user) {
        resetCachedUserCache();
        return null;
      }

      const tokens = await user.currentSession.getTokens();

      if (!tokens.accessToken) {
        resetCachedUserCache();
        return null;
      }
      window.cachedUser = user;
      window.userPromise = null;
      return user;
    } catch (error) {
      console.error("Error fetching user:", error);
      resetCachedUserCache();
      return null;
    } finally {
      window.userPromise = null;
    }
  })();

  return window.userPromise;
}
