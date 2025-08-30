import { FlatCompat } from "@eslint/eslintrc";
import js from "@eslint/js";

const compat = new FlatCompat({
  baseDirectory: import.meta.dirname,
  recommendedConfig: js.configs.recommended,
});

const eslintConfig = [
  {
    ignores: [".next/**/*"],
  },
  ...compat.config({
    extends: ["eslint:recommended", "next"],
  }),
];

export default eslintConfig;
