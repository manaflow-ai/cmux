import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  transpilePackages: ["@cmux/client"],
  env: {
    NEXT_PUBLIC_STACK_PROJECT_ID: process.env.NEXT_PUBLIC_STACK_PROJECT_ID,
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY:
      process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
    NEXT_PUBLIC_WWW_ORIGIN: process.env.NEXT_PUBLIC_WWW_ORIGIN,
  },
  serverExternalPackages: ["morphcloud", "ssh2", "node-ssh", "cpu-features"],
  webpack: (config, { isServer }) => {
    if (isServer) {
      const externals = ["morphcloud", "ssh2", "node-ssh", "cpu-features"];
      config.externals = Array.isArray(config.externals)
        ? [...config.externals, ...externals]
        : config.externals
          ? [config.externals, ...externals]
          : externals;
    }
    return config;
  },
};

export default nextConfig;
